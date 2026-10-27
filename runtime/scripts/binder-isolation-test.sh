#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
# shellcheck disable=SC1091
. "$script_dir/binder-identity-lib.sh"
default_image=$("$script_dir/default-image.sh" standard x86_64)
image=${1:-${ROYD_IMAGE:-$default_image}}
timeout=${ROYD_BOOT_TIMEOUT:-180}
hal_profile=${ROYD_HAL_PROFILE:-graphical}
profile=${ROYD_PROFILE:-$("$script_dir/default-runtime-profile.sh")}
security_mode=${ROYD_SECURITY_MODE:-privileged}
prefix=${ROYD_BINDER_PREFIX:-royd-binder-$$}
container_a=${prefix}-a
container_b=${prefix}-b
volume_a=${container_a}-data
volume_b=${container_b}-data
output=${ROYD_BINDER_OUTPUT_DIR:-$repo_root/.work/binder-isolation-$(date -u +%Y%m%dT%H%M%SZ)-$$}
wait_runner=${ROYD_BINDER_WAIT_RUNNER:-$script_dir/wait-for-boot.sh}
assert_runner=${ROYD_BINDER_ASSERT_RUNNER:-$script_dir/assert-runtime.sh}
owner=$(cat /proc/sys/kernel/random/uuid)
created_a=0
created_b=0
volume_owned_a=0
volume_owned_b=0
id_a=unknown
id_b=unknown
boot_a=not-run
boot_b=not-run
runtime_a=not-run
runtime_b=not-run
identity_status=not-run
capture_a=not-run
capture_b=not-run
cleanup_a=not-run
cleanup_b=not-run
result=fail
started=$(date -u +%Y-%m-%dT%H:%M:%SZ)

profile_args=$("$script_dir/profile.sh" "$profile")
security_args=$("$script_dir/security-args.sh" "$security_mode")
container_args=$("$script_dir/container-args.sh")
runtime_arch=${ROYD_ARCH:-${ROYD_QUALIFY_ARCH:-x86_64}}
gpu_args=$(ROYD_GRAPHICS_ARCH="$runtime_arch" "$script_dir/gpu-args.sh" "${ROYD_GRAPHICS_BACKEND:-software}" "$runtime_arch")

case "$output" in ''|/|.|..) printf '%s\n' 'error: unsafe Binder evidence directory' >&2; exit 2 ;; esac
[ "$output" != "$repo_root" ] || exit 2
# Existing names and evidence are never adopted, removed or overwritten.
for candidate in "$container_a" "$container_b"; do
  if docker inspect "$candidate" >/dev/null 2>&1 || docker volume inspect "$candidate-data" >/dev/null 2>&1; then
    printf 'error: Binder test resource already exists: %s\n' "$candidate" >&2
    exit 1
  fi
done
mkdir -p "$(dirname -- "$output")"
mkdir "$output" || { printf '%s\n' 'error: Binder evidence directory must be new' >&2; exit 1; }
output=$(CDPATH= cd -- "$output" && pwd)

container_owner() {
  actual=$(docker inspect --format '{{index .Config.Labels "org.royd.test.owner"}} {{.Id}} {{.Image}}' "$1") || return 1
  [ "$actual" = "$owner $2 $image" ]
}

retain_and_remove() {
  side=$1
  eval 'created=$created_'"$side" 'volume_owned=$volume_owned_'"$side" 'id=$id_'"$side" 'container=$container_'"$side" 'volume=$volume_'"$side"
  if [ "$created" = 1 ]; then
    eval "capture_$side=fail"
    container_owner "$container" "$id" || return 1
    "$script_dir/container-evidence.sh" "$id" "$output/$side" >"$output/$side-capture.log" 2>&1 || return 1
    # Watchdog thread dumps can live only in the disposable /data volume.
    # Record an unavailable probe honestly; do not call it proof of no ANR.
    if timeout 5 docker exec "$id" test -d /data/anr >"$output/$side/anr-capture.log" 2>&1; then
      docker cp "$id:/data/anr" "$output/$side/anr" >>"$output/$side/anr-capture.log" 2>&1 || return 1
      printf '%s\n' 'ANR_COPY_STATUS=pass' >"$output/$side/anr-status.env"
    else
      printf 'ANR_PROBE_STATUS=%s\n' "$?" >"$output/$side/anr-status.env"
    fi
    eval "capture_$side=pass"
    # Recheck before deletion and remove by immutable ID, never a recycled name.
    container_owner "$container" "$id" || return 1
    docker rm -f "$id" >"$output/$side-container-cleanup.log" 2>&1 || return 1
  fi
  if [ "$volume_owned" = 1 ]; then
    actual=$(docker volume inspect --format '{{index .Labels "org.royd.test.owner"}}' "$volume") || return 1
    [ "$actual" = "$owner" ] || return 1
    docker volume rm "$volume" >"$output/$side-volume-cleanup.log" 2>&1 || return 1
  fi
  eval "cleanup_$side=pass"
}

finish() {
  exit_status=$?
  trap - EXIT HUP INT TERM
  [ "$exit_status" -eq 0 ] || result=fail
  retain_and_remove a || { cleanup_a=fail; result=fail; exit_status=1; }
  retain_and_remove b || { cleanup_b=fail; result=fail; exit_status=1; }
  cat >"$output/manifest.env" <<MANIFEST
ROYD_BINDER_EVIDENCE_FORMAT=1
RESULT_STATUS=$result
IMAGE_ID=$image
CONTAINER_A=$id_a
CONTAINER_B=$id_b
BOOT_A_STATUS=$boot_a
BOOT_B_STATUS=$boot_b
RUNTIME_A_STATUS=$runtime_a
RUNTIME_B_STATUS=$runtime_b
IDENTITY_STATUS=$identity_status
CAPTURE_A_STATUS=$capture_a
CAPTURE_B_STATUS=$capture_b
CLEANUP_A_STATUS=$cleanup_a
CLEANUP_B_STATUS=$cleanup_b
STARTED_AT=$started
FINISHED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
MANIFEST
  printf 'Binder isolation evidence: %s\n' "$output"
  if [ "$result" = pass ]; then
    printf '%s\n' 'Binder isolation test passed: private binderfs devices have distinct kernel device identities'
  else
    printf '%s\n' 'error: Binder isolation failed; inspect retained evidence and any resources left after capture/ownership failure' >&2
    [ "$exit_status" -ne 0 ] || exit_status=1
  fi
  exit "$exit_status"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM

run_stage() {
  if "$@" >"$output/$phase.log" 2>&1; then
    eval "$phase=pass"
    cat "$output/$phase.log"
  else
    stage_status=$?
    eval "$phase=fail"
    cat "$output/$phase.log"
    return "$stage_status"
  fi
}

image=$(docker image inspect --format '{{.Id}}' "$image")
printf 'Starting Binder isolation test with %s using HAL profile %s\n' "$image" "$hal_profile"
for side in a b; do
  eval 'container=$container_'"$side" 'volume=$volume_'"$side"
  docker volume create --label "org.royd.test.owner=$owner" "$volume" >"$output/$side-volume-create.log"
  eval "volume_owned_$side=1"
  actual=$(docker volume inspect --format '{{index .Labels "org.royd.test.owner"}}' "$volume")
  [ "$actual" = "$owner" ]
  # Word splitting is intentional: these helpers emit trusted runtime arguments.
  # shellcheck disable=SC2086
  id=$(docker create $security_args $gpu_args $container_args --name "$container" \
    --label "org.royd.test=binder-isolation" --label "org.royd.test.owner=$owner" \
    -v "$volume:/data" "$image" $profile_args)
  eval "id_$side=\$id" "created_$side=1"
  container_owner "$container" "$id"
  docker start "$id" >"$output/$side-start.log"
done

phase=boot_a; run_stage "$wait_runner" "$container_a" "$timeout"
phase=boot_b; run_stage "$wait_runner" "$container_b" "$timeout"
phase=runtime_a; run_stage "$assert_runner" "$container_a"
phase=runtime_b; run_stage "$assert_runner" "$container_b"

docker exec "$container_a" /vendor/bin/royd-binder-info >"$output/a-identity.txt"
docker exec "$container_b" /vendor/bin/royd-binder-info >"$output/b-identity.txt"
identity_a=$(cat "$output/a-identity.txt")
identity_b=$(cat "$output/b-identity.txt")

identity_status=fail
binder_identities_isolated "$identity_a" "$identity_b" || {
  printf '%s\n' 'error: Binder device identities are missing or shared between the two containers' >&2
  printf 'container A:\n%s\ncontainer B:\n%s\n' "$identity_a" "$identity_b" >&2
  exit 1
}

identity_status=pass
result=pass
