#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
image=${1:-${ROYD_IMAGE:-$($script_dir/default-image.sh standard x86_64)}}
output=${ROYD_RESTART_OUTPUT_DIR:-$repo_root/.work/restart-$(date -u +%Y%m%dT%H%M%SZ)-$$}
container=royd-restart-$$
volume=$container-data
profile=${ROYD_PROFILE:-default}
resource_profile=${ROYD_RESOURCE_PROFILE:-low-memory}
security_mode=${ROYD_SECURITY_MODE:-privileged}
graphics_backend=${ROYD_GRAPHICS_BACKEND:-software}
arch=${ROYD_ARCH:-x86_64}
timeout=${ROYD_BOOT_TIMEOUT:-180}
health_timeout=${ROYD_HEALTH_TIMEOUT:-240}
wait_runner=${ROYD_RESTART_WAIT_RUNNER:-$script_dir/wait-for-boot.sh}
health_runner=${ROYD_RESTART_HEALTH_RUNNER:-$script_dir/wait-for-health.sh}
assert_runner=${ROYD_RESTART_ASSERT_RUNNER:-$script_dir/assert-runtime.sh}
security_runner=${ROYD_RESTART_SECURITY_RUNNER:-$script_dir/assert-security.sh}
phase=fresh
result=fail
fresh_status=not-run
restart_status=not-run
recreate_status=not-run
container_owned=0
volume_owned=0
image_id=unknown
started=$(date -u +%Y-%m-%dT%H:%M:%SZ)

command -v docker >/dev/null 2>&1 || { printf '%s\n' 'error: docker is required' >&2; exit 1; }
case "$output" in ''|/|.|..) printf '%s\n' 'error: unsafe restart evidence directory' >&2; exit 2 ;; esac
# Never adopt or delete an existing container, volume or evidence directory.
if docker inspect "$container" >/dev/null 2>&1 || docker volume inspect "$volume" >/dev/null 2>&1; then
  printf '%s\n' 'error: restart test resource already exists' >&2
  exit 1
fi
mkdir -p "$(dirname -- "$output")"
mkdir "$output" || { printf '%s\n' 'error: restart evidence directory must be new' >&2; exit 1; }

capture() {
  "$script_dir/container-evidence.sh" "$container" "$output/$phase" >>"$output/$phase/capture.log" 2>&1
}

finish() {
  exit_status=$?
  trap - EXIT HUP INT TERM
  if [ "$exit_status" -ne 0 ]; then
    result=fail
    eval "${phase}_status=fail"
    if [ "$container_owned" = 1 ]; then
      mkdir -p "$output/$phase"
      capture || printf '%s\n' 'error: failed to retain container evidence' >&2
    fi
  fi
  cat >"$output/manifest.env" <<MANIFEST
ROYD_RESTART_EVIDENCE_FORMAT=1
RESULT_STATUS=$result
FRESH_STATUS=$fresh_status
RESTART_STATUS=$restart_status
RECREATE_STATUS=$recreate_status
IMAGE=$image
IMAGE_ID=$image_id
ARCH=$arch
DISPLAY_PROFILE=$profile
RESOURCE_PROFILE=$resource_profile
SECURITY_MODE=$security_mode
GRAPHICS_BACKEND=$graphics_backend
STARTED_AT=$started
FINISHED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
MANIFEST
  if [ "$container_owned" = 1 ]; then docker rm -f "$container" >/dev/null 2>&1 || true; fi
  if [ "$volume_owned" = 1 ]; then docker volume rm "$volume" >/dev/null 2>&1 || true; fi
  exit "$exit_status"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM

image_id=$(docker image inspect --format '{{.Id}}' "$image")
profile_args=$(ROYD_RESOURCE_PROFILE="$resource_profile" "$script_dir/profile.sh" "$profile")
security_args=$("$script_dir/security-args.sh" "$security_mode")
container_args=$("$script_dir/container-args.sh")
gpu_args=$(ROYD_GRAPHICS_ARCH="$arch" "$script_dir/gpu-args.sh" "$graphics_backend" "$arch")
docker volume create "$volume" >"$output/volume.log"
volume_owned=1

create_container() {
  # The resolved image ID pins all phases even if a development alias changes.
  # Word splitting is intentional for trusted repository-generated arguments.
  # shellcheck disable=SC2086
  docker create $security_args $gpu_args $container_args --name "$container" \
    -v "$volume:/data" "$image_id" $profile_args >"$output/$phase/create.log"
  container_owned=1
  docker start "$container" >>"$output/$phase/create.log"
}

check_phase() {
  "$wait_runner" "$container" "$timeout"
  "$health_runner" "$container" "$health_timeout"
  "$security_runner" "$container" "$security_mode"
  [ "$(docker exec "$container" getprop ro.build.version.sdk | tr -d '\r')" = 35 ]
  ROYD_HAL_PROFILE=graphical ROYD_GRAPHICS_BACKEND="$graphics_backend" \
    ROYD_RESOURCE_PROFILE="$resource_profile" "$assert_runner" "$container"
}

# Execute the same Android-side read in all phases, not a host-side mock checksum.
read_persistence() {
  docker exec "$container" sh -c '
    # royd-restart-read-persistence
    set -eu
    sha256sum /data/local/tmp/royd-restart-probe
    settings get global royd_restart_probe
    settings get secure android_id
    cmd package list packages -U org.chromium.webview_shell
  '
}

mkdir "$output/$phase"
create_container
check_phase >"$output/$phase/runtime.log" 2>&1
docker exec "$container" sh -c '
  # royd-restart-seed-persistence
  set -eu
  token=$1
  printf "%s\n" "$token" > /data/local/tmp/royd-restart-probe
  settings put global royd_restart_probe "$token"
  # Settings writes asynchronously. Establish durable XML before stopping init.
  attempt=0
  until grep -Fq "$token" /data/system/users/0/settings_global.xml; do
    attempt=$((attempt + 1))
    [ "$attempt" -lt 10 ] || exit 1
    sleep 1
  done
  sync
' sh "$container-$started" >"$output/$phase/seed.log" 2>&1
read_persistence >"$output/$phase/persistence.txt"
# Reject an absent setting/identity/package before equality comparisons can pass.
sed -n '1p' "$output/$phase/persistence.txt" | grep -Eq '^[0-9a-f]{64}  /data/local/tmp/royd-restart-probe$'
[ "$(sed -n '2p' "$output/$phase/persistence.txt")" = "$container-$started" ]
sed -n '3p' "$output/$phase/persistence.txt" | grep -Eq '^[0-9a-f]{16}$'
sed -n '4p' "$output/$phase/persistence.txt" | grep -Eq '^package:org.chromium.webview_shell uid:[0-9]+$'
[ "$(wc -l <"$output/$phase/persistence.txt")" -eq 4 ]
docker inspect --format '{{.Id}} {{.State.StartedAt}}' "$container" >"$output/$phase/identity.txt"
capture
fresh_status=pass

phase=restart
mkdir "$output/$phase"
docker restart -t 10 "$container" >"$output/$phase/restart.log" 2>&1
check_phase >"$output/$phase/runtime.log" 2>&1
read_persistence >"$output/$phase/persistence.txt"
cmp "$output/fresh/persistence.txt" "$output/$phase/persistence.txt"
docker inspect --format '{{.Id}} {{.State.StartedAt}}' "$container" >"$output/$phase/identity.txt"
[ "$(cut -d ' ' -f 1 "$output/fresh/identity.txt")" = "$(cut -d ' ' -f 1 "$output/$phase/identity.txt")" ]
[ "$(cut -d ' ' -f 2 "$output/fresh/identity.txt")" != "$(cut -d ' ' -f 2 "$output/$phase/identity.txt")" ]
capture
restart_status=pass

phase=recreate
mkdir "$output/$phase"
docker stop -t 10 "$container" >"$output/$phase/remove.log" 2>&1
docker rm "$container" >>"$output/$phase/remove.log" 2>&1
container_owned=0
create_container
check_phase >"$output/$phase/runtime.log" 2>&1
read_persistence >"$output/$phase/persistence.txt"
cmp "$output/fresh/persistence.txt" "$output/$phase/persistence.txt"
docker inspect --format '{{.Id}} {{.State.StartedAt}}' "$container" >"$output/$phase/identity.txt"
[ "$(cut -d ' ' -f 1 "$output/fresh/identity.txt")" != "$(cut -d ' ' -f 1 "$output/$phase/identity.txt")" ]
capture
recreate_status=pass
result=pass
printf 'Android 15 persistent-data restart test passed: %s\n' "$output"
