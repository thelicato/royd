#!/bin/sh
# Reproduce early OCI exec overlap. The temporary entrypoint is diagnostic only;
# these modified containers do not substitute for unmodified image qualification.
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
image=${1:-$("$script_dir/default-image.sh")}
output=${ROYD_CGROUP_DELEGATION_OUTPUT_DIR:-$repo_root/.work/cgroup-delegation}
case "$output" in /*) ;; *) printf '%s\n' 'error: use an absolute evidence path' >&2; exit 2 ;; esac
[ ! -e "$output" ] || { printf 'error: evidence already exists: %s\n' "$output" >&2; exit 2; }
for command in docker cc; do
    command -v "$command" >/dev/null || exit 1
done
if [ -n "${DOCKER_CONTEXT:-}" ]; then
    endpoint=$(docker context inspect "$DOCKER_CONTEXT" --format '{{.Endpoints.docker.Host}}')
elif [ -n "${DOCKER_HOST:-}" ]; then
    endpoint=$DOCKER_HOST
else
    endpoint=$(docker context inspect --format '{{.Endpoints.docker.Host}}')
fi
case "$endpoint" in unix://*) ;; *) printf '%s\n' 'error: local Unix-socket Docker is required' >&2; exit 2 ;; esac
image=$(docker image inspect --format '{{.Id}}' "$image")
test "$(docker image inspect --format '{{.Architecture}}' "$image")" = amd64
test "$(uname -m)" = x86_64
mkdir -p "$output"
cc -static -O2 -Wall -Wextra -Werror "$repo_root/runtime/tests/cgroup-delegation-probe.c" -o "$output/probe"
printf 'format=1\nimage=%s\ndiagnostic_entrypoint=1\n' "$image" > "$output/manifest.env"
container=
volume=
container_owned=0
volume_owned=0
hold_job=
phase_output=
capture_cleanup() {
    cleanup_status=0
    if [ "$container_owned" = 1 ]; then
        "$script_dir/container-evidence.sh" "$container" "$phase_output/container" || cleanup_status=1
        if docker rm -f "$container" >/dev/null; then container_owned=0; else cleanup_status=1; fi
    fi
    if [ -n "$hold_job" ]; then wait "$hold_job" || true; hold_job=; fi
    if [ "$volume_owned" = 1 ]; then
        if docker volume rm "$volume" >/dev/null; then volume_owned=0; else cleanup_status=1; fi
    fi
    return "$cleanup_status"
}
finish() {
    result=$?
    trap - EXIT HUP INT TERM
    capture_cleanup || result=1
    printf 'exit_code=%s\n' "$result" >> "$output/manifest.env"
    exit "$result"
}
trap finish EXIT
trap 'exit 1' HUP INT TERM
for phase in transient persistent; do
    phase_output=$output/$phase
    mkdir "$phase_output"
    container=royd-cgroup-delegation-$phase-$$
    volume=$container-data
    if docker inspect "$container" >/dev/null 2>&1 || docker volume inspect "$volume" >/dev/null 2>&1; then
        printf '%s\n' 'error: refusing existing resources' >&2
        exit 1
    fi
    docker volume create "$volume" > "$phase_output/volume.log"
    volume_owned=1
    security_args=$("$script_dir/security-args.sh" privileged)
    container_args=$("$script_dir/container-args.sh")
    # The only payload modification is the copied static probe and entrypoint.
    # shellcheck disable=SC2086
    docker create $security_args $container_args --name "$container" -v "$volume:/data" \
        --entrypoint /royd-cgroup-probe "$image" gate > "$phase_output/create.log"
    container_owned=1
    docker cp "$output/probe" "$container:/royd-cgroup-probe"
    docker start "$container" > "$phase_output/start.log"
    case "$phase" in transient) seconds=5 ;; persistent) seconds=15 ;; esac
    docker exec "$container" /royd-cgroup-probe hold "$seconds" > "$phase_output/hold.log" 2>&1 &
    hold_job=$!
    init_pid=$(docker inspect --format '{{.State.Pid}}' "$container")
    cgroup_root=/proc/$init_pid/root/sys/fs/cgroup
    # Read through the target mount namespace from the host. No observation exec
    # may create another root member while proving the deliberate overlap.
    sleep 1
    holder=
    for member in $(cat "$cgroup_root/cgroup.procs"); do
        command_line=$(tr '\000' ' ' < "/proc/$member/cmdline" 2>/dev/null || true)
        printf '%s %s\n' "$member" "$command_line" >> "$phase_output/root-members-before.log"
        case "$command_line" in *'/royd-cgroup-probe hold '*) holder=$member ;; esac
    done
    test -n "$holder"
    tries=0
    until docker logs "$container" > "$phase_output/early.log" 2>&1 &&
        grep -Fq 'ROYD: waiting for busy container memory delegation' "$phase_output/early.log"; do
        tries=$((tries + 1)); test "$tries" -lt 100
        sleep 0.1
    done
    cat "$cgroup_root/cgroup.procs" > "$phase_output/root-members-waiting.log"
    grep -Fxq "$holder" "$phase_output/root-members-waiting.log"
    kill -0 "$holder"
    test "$(cat "$cgroup_root/royd/init/cgroup.procs")" = "$init_pid"
    wait "$hold_job"
    hold_job=
    docker logs "$container" > "$phase_output/after-hold.log" 2>&1
    if [ "$phase" = transient ]; then
        ROYD_BOOT_WAIT_MARKER='ROYD: using delegated cgroup v2 subtree' \
            "$script_dir/wait-for-boot.sh" "$container" > "$phase_output/boot.log" 2>&1
        "$script_dir/wait-for-health.sh" "$container" > "$phase_output/health.log" 2>&1
        "$script_dir/assert-runtime.sh" "$container" > "$phase_output/runtime.log" 2>&1
        docker logs "$container" > "$phase_output/after-runtime.log" 2>&1
        grep -Fq 'ROYD: enabled container memory delegation after retry' "$phase_output/after-runtime.log"
        if grep -Fq 'Failed to delegate the memory controller' "$phase_output/after-runtime.log"; then
            printf '%s\n' 'error: delegation failed in recovered container' >&2
            exit 1
        fi
    else
        grep -Fq 'Failed to delegate the memory controller to /sys/fs/cgroup/royd: Device or resource busy' "$phase_output/after-hold.log"
        if grep -Fq 'ROYD: using delegated cgroup v2 subtree' "$phase_output/after-hold.log" ||
            grep -Fq 'ROYD: enabled container memory delegation after retry' "$phase_output/after-hold.log"; then
            printf '%s\n' 'error: false success in persistent-busy container' >&2
            exit 1
        fi
        # Setup failure is not fatal to stock CgroupSetup. Verify unavailable
        # interfaces, never claim this negative container is a passing runtime.
        if docker exec "$container" sh -c 'test -f /sys/fs/cgroup/royd/init/memory.low'; then
            printf '%s\n' 'error: unexpected memory delegation in negative case' >&2
            exit 1
        fi
    fi
    printf '%s=pass\n' "$phase" >> "$output/manifest.env"
    capture_cleanup
done
printf '%s\n' 'Transient recovery and bounded persistent failure passed'
