#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
default_image=$("$script_dir/default-image.sh" standard x86_64)
image=${1:-${ROYD_IMAGE:-$default_image}}
duration=${ROYD_SCRCPY_DURATION:-30}
bit_rate=${ROYD_SCRCPY_BIT_RATE:-2M}
minimum_bytes=${ROYD_SCRCPY_MINIMUM_BYTES:-32768}
output=${ROYD_SCRCPY_OUTPUT_DIR:-$repo_root/.work/scrcpy-stability}
replace=${ROYD_SCRCPY_REPLACE:-0}
adb_server_port=${ROYD_SCRCPY_ADB_SERVER_PORT:-5038}
container=${ROYD_SCRCPY_CONTAINER:-royd-scrcpy-$$}
volume=${container}-data
timeout=${ROYD_BOOT_TIMEOUT:-180}
health_timeout=${ROYD_HEALTH_TIMEOUT:-240}
profile=${ROYD_PROFILE:-$("$script_dir/default-runtime-profile.sh")}
security_mode=${ROYD_SECURITY_MODE:-privileged}
runtime_arch=${ROYD_ARCH:-${ROYD_QUALIFY_ARCH:-x86_64}}
graphics_backend=${ROYD_GRAPHICS_BACKEND:-software}
resource_profile=${ROYD_RESOURCE_PROFILE:-low-memory}
docker_command=${ROYD_DOCKER_COMMAND:-docker}
adb_command=${ROYD_ADB_COMMAND:-adb}
scrcpy_command=${ROYD_SCRCPY_COMMAND:-scrcpy}
wait_runner=${ROYD_SCRCPY_WAIT_RUNNER:-$script_dir/wait-for-boot.sh}
health_runner=${ROYD_SCRCPY_HEALTH_RUNNER:-$script_dir/wait-for-health.sh}
assert_runner=${ROYD_SCRCPY_ASSERT_RUNNER:-$script_dir/assert-runtime.sh}
adb_socket="tcp:localhost:$adb_server_port"
workload_pid=

positive_integer() {
  name=$1
  value=$2
  case "$value" in
    ''|*[!0-9]*|0)
      printf 'error: %s must be a positive integer: %s\n' "$name" "$value" >&2
      exit 2
      ;;
  esac
}

positive_integer ROYD_SCRCPY_DURATION "$duration"
positive_integer ROYD_SCRCPY_MINIMUM_BYTES "$minimum_bytes"
positive_integer ROYD_SCRCPY_ADB_SERVER_PORT "$adb_server_port"
case "$replace" in 0|1) ;; *) printf '%s\n' 'error: ROYD_SCRCPY_REPLACE must be 0 or 1' >&2; exit 2 ;; esac
case "$bit_rate" in
  ''|*[!0-9kKmM]*)
    printf 'error: invalid scrcpy video bit rate: %s\n' "$bit_rate" >&2
    exit 2
    ;;
esac
case "$output" in /|.) printf '%s\n' 'error: unsafe scrcpy evidence directory' >&2; exit 2 ;; esac
[ "$output" != "$repo_root" ] || { printf '%s\n' 'error: scrcpy evidence directory cannot be the repository root' >&2; exit 2; }

for command in "$docker_command" "$adb_command" "$scrcpy_command" timeout; do
  command -v "$command" >/dev/null 2>&1 || {
    printf 'error: required command is unavailable: %s\n' "$command" >&2
    exit 1
  }
done

if [ -e "$output" ]; then
  if [ "$replace" -eq 1 ]; then
    [ -f "$output/.royd-scrcpy-evidence" ] || {
      printf 'error: refusing to replace an unrecognised directory: %s\n' "$output" >&2
      exit 2
    }
    rm -rf "$output"
  else
    printf 'error: scrcpy evidence directory already exists: %s\n' "$output" >&2
    exit 2
  fi
fi
mkdir -p "$output"
: >"$output/.royd-scrcpy-evidence"

adb_run() {
  ADB_SERVER_SOCKET="$adb_socket" "$adb_command" "$@"
}

cleanup() {
  if [ -n "$workload_pid" ]; then
    kill "$workload_pid" >/dev/null 2>&1 || true
    wait "$workload_pid" >/dev/null 2>&1 || true
  fi
  adb_run disconnect >/dev/null 2>&1 || true
  adb_run kill-server >/dev/null 2>&1 || true
  "$docker_command" rm -f "$container" >/dev/null 2>&1 || true
  "$docker_command" volume rm "$volume" >/dev/null 2>&1 || true
}
trap cleanup EXIT HUP INT TERM
cleanup
workload_pid=

"$docker_command" image inspect "$image" >/dev/null 2>&1 || {
  printf 'error: image not found: %s\n' "$image" >&2
  exit 1
}

profile_args=$(ROYD_RESOURCE_PROFILE="$resource_profile" "$script_dir/profile.sh" "$profile")
display_width=$(printf '%s\n' "$profile_args" | sed -n 's/^royd.width=//p')
display_height=$(printf '%s\n' "$profile_args" | sed -n 's/^royd.height=//p')
swipe_x=$((display_width / 2))
swipe_top=$((display_height / 4))
swipe_bottom=$((display_height * 3 / 4))
security_args=$("$script_dir/security-args.sh" "$security_mode")
container_args=$("$script_dir/container-args.sh")
gpu_args=$(ROYD_GRAPHICS_ARCH="$runtime_arch" "$script_dir/gpu-args.sh" "$graphics_backend" "$runtime_arch")

"$docker_command" volume create "$volume" >/dev/null
# Word splitting is intentional because helper scripts emit trusted arguments.
# shellcheck disable=SC2086
"$docker_command" run -d $security_args $gpu_args $container_args \
  --name "$container" -p 127.0.0.1::5555 -v "$volume:/data" \
  "$image" $profile_args >/dev/null

"$wait_runner" "$container" "$timeout"
"$health_runner" "$container" "$health_timeout"
ROYD_RESOURCE_PROFILE="$resource_profile" "$assert_runner" "$container"
binding=$("$docker_command" port "$container" 5555/tcp 2>/dev/null | head -n 1 || true)
case "$binding" in
  *:*) adb_port=${binding##*:} ;;
  *) printf '%s\n' 'error: Docker did not publish the Android ADB port' >&2; exit 1 ;;
esac
serial="127.0.0.1:$adb_port"

"$adb_command" -L "$adb_socket" start-server >/dev/null
adb_run connect "$serial" >/dev/null
[ "$(adb_run -s "$serial" get-state 2>/dev/null || true)" = device ] || {
  printf 'error: ADB device is not ready at %s\n' "$serial" >&2
  exit 1
}
adb_run -s "$serial" shell input keyevent 82 >/dev/null 2>&1 || true
adb_run -s "$serial" shell input keyevent HOME >/dev/null

workload_log="$output/workload.log"
: >"$workload_log"
(
  deadline=$(($(date +%s) + duration - 1))
  cycles=0
  sleep 2
  while [ "$(date +%s)" -lt "$deadline" ]; do
    adb_run -s "$serial" shell am start -W -n com.android.settings/.Settings >>"$workload_log" 2>&1
    adb_run -s "$serial" shell input swipe "$swipe_x" "$swipe_bottom" \
      "$swipe_x" "$swipe_top" 350 >>"$workload_log" 2>&1
    adb_run -s "$serial" shell input keyevent HOME >>"$workload_log" 2>&1
    cycles=$((cycles + 1))
    sleep 1
  done
  printf 'cycles=%s\n' "$cycles" >>"$workload_log"
) &
workload_pid=$!

recording="$output/scrcpy.mp4"
scrcpy_log="$output/scrcpy.log"
started_epoch=$(date +%s)
set +e
ADB_SERVER_SOCKET="$adb_socket" timeout "$((duration + 30))" \
  "$scrcpy_command" --serial "$serial" --no-window --no-audio \
  --video-codec=h264 --video-bit-rate="$bit_rate" --time-limit="$duration" \
  --start-app=+com.android.settings --record "$recording" \
  --verbosity=debug >"$scrcpy_log" 2>&1
scrcpy_status=$?
set -e
ended_epoch=$(date +%s)
elapsed_seconds=$((ended_epoch - started_epoch))
wait "$workload_pid"
workload_pid=

[ "$scrcpy_status" -eq 0 ] || {
  printf 'error: scrcpy exited with status %s\n' "$scrcpy_status" >&2
  tail -n 80 "$scrcpy_log" >&2
  exit 1
}
[ -f "$recording" ] || { printf '%s\n' 'error: scrcpy did not produce a recording' >&2; exit 1; }
recording_bytes=$(wc -c <"$recording" | tr -d ' ')
[ "$recording_bytes" -ge "$minimum_bytes" ] || {
  printf 'error: scrcpy recording is too small: %s bytes\n' "$recording_bytes" >&2
  exit 1
}
[ "$elapsed_seconds" -ge "$duration" ] || {
  printf 'error: scrcpy stream ended early after %s seconds\n' "$elapsed_seconds" >&2
  exit 1
}

"$docker_command" inspect "$container" >"$output/container-inspect.json"
"$docker_command" logs "$container" >"$output/container.log" 2>&1
scrcpy_version=$("$scrcpy_command" --version 2>/dev/null | head -n 1)
image_id=$("$docker_command" image inspect --format '{{.Id}}' "$image" 2>/dev/null || printf unknown)
recording_sha256=$(sha256sum "$recording" | awk '{print $1}')
workload_cycles=$(sed -n 's/^cycles=//p' "$workload_log" | tail -n 1)
[ -n "$workload_cycles" ] || workload_cycles=0
cat >"$output/manifest.env" <<MANIFEST
ROYD_SCRCPY_EVIDENCE_FORMAT=1
RESULT_STATUS=pass
IMAGE=$image
IMAGE_ID=$image_id
ARCH=$runtime_arch
DISPLAY_PROFILE=$profile
RESOURCE_PROFILE=$resource_profile
SECURITY_MODE=$security_mode
GRAPHICS_BACKEND=$graphics_backend
SCRCPY_VERSION=$scrcpy_version
VIDEO_CODEC=h264
VIDEO_BIT_RATE=$bit_rate
REQUESTED_DURATION_SECONDS=$duration
ELAPSED_SECONDS=$elapsed_seconds
WORKLOAD_CYCLES=$workload_cycles
RECORDING_BYTES=$recording_bytes
RECORDING_SHA256=$recording_sha256
MANIFEST

printf 'scrcpy stability test passed: %s seconds, %s bytes\n' "$elapsed_seconds" "$recording_bytes"
printf 'Evidence written to %s\n' "$output"
