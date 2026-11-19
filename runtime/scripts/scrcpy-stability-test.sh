#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
default_image=$("$script_dir/default-image.sh" standard x86_64)
image=${1:-${ROYD_IMAGE:-$default_image}}
duration=${ROYD_SCRCPY_DURATION:-30}
bit_rate=${ROYD_SCRCPY_BIT_RATE:-2M}
minimum_bytes=${ROYD_SCRCPY_MINIMUM_BYTES:-32768}
evidence_dir=${ROYD_SCRCPY_OUTPUT_DIR:-$repo_root/.work/scrcpy-stability}
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
adb_dir=
adb_pid=
adb_start=
workload_pid=
workload_start=
workload_started=0
container_id=unknown
volume_owned=0
created=0
image_id=unknown
boot_status=not-run
health_status=not-run
pre_runtime_status=not-run
post_runtime_status=not-run
capture_status=not-run
cleanup_status=not-run
scrcpy_version=unknown
elapsed_seconds=0
workload_cycles=0
recording_bytes=0
recording_sha256=unavailable
recording_status=not-run

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
case "$bit_rate" in
  ''|*[!0-9kKmM]*)
    printf 'error: invalid scrcpy video bit rate: %s\n' "$bit_rate" >&2
    exit 2
    ;;
esac
case "$evidence_dir" in /|.|..) printf '%s\n' 'error: unsafe scrcpy evidence directory' >&2; exit 2 ;; esac
[ "$evidence_dir" != "$repo_root" ] || { printf '%s\n' 'error: scrcpy evidence directory cannot be the repository root' >&2; exit 2; }

for command in "$docker_command" "$adb_command" "$scrcpy_command" timeout; do
  command -v "$command" >/dev/null 2>&1 || {
    printf 'error: required command is unavailable: %s\n' "$command" >&2
    exit 1
  }
done

for name in "$container" "$volume"; do
  if "$docker_command" inspect "$name" >/dev/null 2>&1 ||
      "$docker_command" volume inspect "$name" >/dev/null 2>&1; then
    printf 'error: scrcpy resource already exists: %s\n' "$name" >&2
    exit 2
  fi
done
mkdir -p "$(dirname -- "$evidence_dir")"
mkdir "$evidence_dir" || { printf 'error: scrcpy requires a fresh evidence directory: %s\n' "$evidence_dir" >&2; exit 2; }
: >"$evidence_dir/.royd-scrcpy-evidence"
owner=$(cat /proc/sys/kernel/random/uuid)

# shellcheck disable=SC1091
. "$script_dir/qualification-owned-lib.sh"

adb_run() {
  adb_socket_owned || return 1
  ADB_SERVER_SOCKET="$adb_socket" "$adb_command" "$@"
}

process_start() {
  sed 's/^.*) //' "/proc/$1/stat" 2>/dev/null | cut -d ' ' -f 20
}

adb_process_owned() {
  [ -n "$adb_start" ] && [ "$(process_start "$adb_pid")" = "$adb_start" ]
}

adb_socket_owned() {
  adb_process_owned || return 1
  inode=$(awk -v path="$adb_dir/server.sock" '$4 == "00010000" && $8 == path { print $7 }' /proc/net/unix)
  [ -n "$inode" ] || return 1
  for fd in "/proc/$adb_pid/fd/"*; do
    [ "$(readlink "$fd" 2>/dev/null)" != "socket:[$inode]" ] || return 0
  done
  return 1
}

start_adb() {
  adb_dir=$(mktemp -d /tmp/royd-scrcpy-adb.XXXXXXXX) || return 1
  adb_socket="localfilesystem:$adb_dir/server.sock"
  ADB_USB=0 ADB_MDNS=0 ADB_EMU=0 ADB_REJECT_KILL_SERVER=1 \
    "$adb_command" -L "$adb_socket" server nodaemon >"$evidence_dir/adb-server.log" 2>&1 &
  adb_pid=$!
  adb_start=$(process_start "$adb_pid")
  for tick in $(seq 1 60); do
    if adb_socket_owned; then
      printf 'pid=%s\nstart_ticks=%s\nsocket=%s\n' "$adb_pid" "$adb_start" "$adb_socket" \
        >"$evidence_dir/adb-owner.txt"
      return 0
    fi
    adb_process_owned || break
    sleep 0.1
  done
  printf 'error: could not verify a private ADB server in %s\n' "$adb_dir" >&2
  cat "$evidence_dir/adb-server.log" >&2
  return 1
}

stop_adb() {
  [ -z "$adb_dir" ] && return 0
  if [ -S "$adb_dir/server.sock" ] && ! adb_socket_owned; then
    printf 'error: private ADB socket ownership changed in %s\n' "$adb_dir" >&2
    return 1
  fi
  if adb_process_owned; then
    kill "$adb_pid" || return 1
  fi
  wait "$adb_pid" 2>/dev/null || true
  # The socket is inside the fresh, mode-0700 directory created for this server.
  rm -f "$adb_dir/server.sock" && rmdir "$adb_dir"
}

capture_stream() {
  [ "$workload_started" = 1 ] || return 0
  recording_status=fail
  recording_bytes=0
  recording_sha256=unavailable
  for artifact in "$recording" "$workload_log" "$scrcpy_log"; do
    [ -f "$artifact" ] || { printf 'error: streaming evidence is missing: %s\n' "$artifact" >&2; return 1; }
  done
  cat "$workload_log" "$scrcpy_log" >/dev/null || return 1
  recording_size=$(wc -c <"$recording") || return 1
  recording_bytes=$(printf '%s' "$recording_size" | tr -d '[:space:]') || return 1
  [ "$recording_bytes" -ge "$minimum_bytes" ] || {
    printf 'error: final recording has only %s bytes\n' "$recording_bytes" >&2
    return 1
  }
  # Read through stdin so path quoting cannot escape the digest. Keep the
  # reader's exit status instead of hiding a partial failed read in a pipeline.
  captured_digest=$(sha256sum <"$recording") || return 1
  recording_sha256=${captured_digest%% *}
  recording_status=pass
}

retain_and_remove() {
  if [ "$created" = 1 ]; then
    capture_status=fail
    qualification_owner && qualification_volume_owner || return 1
    ROYD_DOCKER_COMMAND="$docker_command" "$script_dir/container-evidence.sh" "$container_id" "$evidence_dir" \
      >"$evidence_dir/container-capture.log" 2>&1 || return 1
    qualification_reports || return 1
    capture_status=pass
    capture_stream >"$evidence_dir/recording-capture.log" 2>&1 || return 1
    qualification_owner && qualification_volume_owner || return 1
    "$docker_command" rm -f "$container_id" >"$evidence_dir/container-cleanup.log" 2>&1 || return 1
  fi
  if [ "$volume_owned" = 1 ]; then
    qualification_volume_owner || return 1
    "$docker_command" volume rm "$volume" >"$evidence_dir/volume-cleanup.log" 2>&1 || return 1
  fi
}

finish() {
  status=$?
  trap - EXIT
  trap '' HUP INT TERM
  if [ -n "$workload_pid" ]; then
    if [ -n "$workload_start" ] && [ "$(process_start "$workload_pid")" = "$workload_start" ]; then
      kill "$workload_pid" >/dev/null 2>&1 || true
    fi
    wait "$workload_pid" >/dev/null 2>&1 || true
  fi
  if [ "$workload_started" = 1 ]; then
    post_runtime_status=fail
    if qualification_owner && qualification_volume_owner &&
        ROYD_RESOURCE_PROFILE="$resource_profile" "$assert_runner" "$container_id" >"$evidence_dir/post-runtime.log" 2>&1; then
      post_runtime_status=pass
    else
      status=1
      printf 'error: post-workload runtime assertions failed; evidence retained in %s\n' "$evidence_dir" >&2
    fi
  fi
  cleanup_status=fail
  if retain_and_remove; then
    cleanup_status=pass
  else
    status=1
    printf 'error: scrcpy capture or cleanup failed; inspect %s and the retained resources\n' "$evidence_dir" >&2
  fi
  if ! stop_adb; then
    status=1
    cleanup_status=fail
  fi
  if [ -f "$workload_log" ]; then
    workload_cycles=$(sed -n 's/^cycles=//p' "$workload_log" | tail -n 1)
    workload_cycles=${workload_cycles:-0}
  fi
  result_status=fail
  [ "$status" -ne 0 ] || result_status=pass
  cat >"$evidence_dir/manifest.env" <<MANIFEST
ROYD_SCRCPY_EVIDENCE_FORMAT=2
RESULT_STATUS=$result_status
BOOT_STATUS=$boot_status
HEALTH_STATUS=$health_status
PRE_RUNTIME_STATUS=$pre_runtime_status
POST_RUNTIME_STATUS=$post_runtime_status
RECORDING_STATUS=$recording_status
CONTAINER_EVIDENCE_STATUS=$capture_status
CLEANUP_STATUS=$cleanup_status
IMAGE=$image
IMAGE_ID=$image_id
CONTAINER_ID=$container_id
RESOURCE_OWNER=$owner
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
  if [ "$result_status" = pass ]; then
    printf 'scrcpy stability test passed: %s seconds, %s bytes\n' "$elapsed_seconds" "$recording_bytes"
  fi
  printf 'Evidence written to %s\n' "$evidence_dir"
  exit "$status"
}

recording="$evidence_dir/scrcpy.mp4"
workload_log="$evidence_dir/workload.log"
scrcpy_log="$evidence_dir/scrcpy.log"
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM

image_id=$("$docker_command" image inspect --format '{{.Id}}' "$image") && [ -n "$image_id" ] || {
  printf 'error: image not found: %s\n' "$image" >&2
  exit 1
}
scrcpy_version=$("$scrcpy_command" --version 2>/dev/null | head -n 1)
start_adb

profile_args=$(ROYD_RESOURCE_PROFILE="$resource_profile" "$script_dir/profile.sh" "$profile")
display_width=$(printf '%s\n' "$profile_args" | sed -n 's/^royd.width=//p')
display_height=$(printf '%s\n' "$profile_args" | sed -n 's/^royd.height=//p')
swipe_x=$((display_width / 2))
swipe_top=$((display_height / 4))
swipe_bottom=$((display_height * 3 / 4))
security_args=$("$script_dir/security-args.sh" "$security_mode")
container_args=$("$script_dir/container-args.sh")
gpu_args=$(ROYD_GRAPHICS_ARCH="$runtime_arch" "$script_dir/gpu-args.sh" "$graphics_backend" "$runtime_arch")

"$docker_command" volume create --label "org.royd.test.owner=$owner" "$volume" >"$evidence_dir/volume-create.log" 2>&1
qualification_volume_owner
volume_owned=1
# Word splitting is intentional because helper scripts emit trusted arguments.
# shellcheck disable=SC2086
container_id=$("$docker_command" create $security_args $gpu_args $container_args \
  --name "$container" --label org.royd.test=scrcpy-stability --label "org.royd.test.owner=$owner" \
  -p 127.0.0.1::5555 -v "$volume:/data" "$image_id" $profile_args 2>"$evidence_dir/container-create.log")
created=1
qualification_owner && qualification_volume_owner || exit 1
"$docker_command" start "$container_id" >"$evidence_dir/container-start.log" 2>&1

boot_status=fail
"$wait_runner" "$container_id" "$timeout" >"$evidence_dir/boot.log" 2>&1
boot_status=pass
health_status=fail
"$health_runner" "$container_id" "$health_timeout" >"$evidence_dir/health.log" 2>&1
health_status=pass
pre_runtime_status=fail
ROYD_RESOURCE_PROFILE="$resource_profile" "$assert_runner" "$container_id" >"$evidence_dir/pre-runtime.log" 2>&1
pre_runtime_status=pass
binding=$("$docker_command" port "$container_id" 5555/tcp 2>/dev/null | head -n 1 || true)
case "$binding" in
  127.0.0.1:*) adb_port=${binding##*:} ;;
  *) printf '%s\n' 'error: Docker did not publish the Android ADB port' >&2; exit 1 ;;
esac
serial="127.0.0.1:$adb_port"

adb_socket_owned
adb_run connect "$serial" >/dev/null
[ "$(adb_run -s "$serial" get-state 2>/dev/null || true)" = device ] || {
  printf 'error: ADB device is not ready at %s\n' "$serial" >&2
  exit 1
}
adb_run -s "$serial" shell input keyevent 82 >/dev/null 2>&1 || true
adb_run -s "$serial" shell input keyevent HOME >/dev/null

: >"$workload_log"
workload_started=1
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
workload_start=$(process_start "$workload_pid")

started_epoch=$(date +%s)
set +e
ADB="$adb_command" ADB_SERVER_SOCKET="$adb_socket" timeout "$((duration + 30))" \
  "$scrcpy_command" --serial "$serial" --no-window --no-audio \
  --video-codec=h264 --video-bit-rate="$bit_rate" --time-limit="$duration" \
  --start-app=+com.android.settings --record "$recording" \
  --verbosity=debug >"$scrcpy_log" 2>&1
scrcpy_status=$?
set -e
ended_epoch=$(date +%s)
elapsed_seconds=$((ended_epoch - started_epoch))
workload_status=0
wait "$workload_pid" || workload_status=$?
workload_pid=

[ "$scrcpy_status" -eq 0 ] || {
  printf 'error: scrcpy exited with status %s\n' "$scrcpy_status" >&2
  tail -n 80 "$scrcpy_log" >&2
  exit 1
}
[ "$workload_status" -eq 0 ] || {
  printf 'error: scrcpy Settings workload exited with status %s\n' "$workload_status" >&2
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
