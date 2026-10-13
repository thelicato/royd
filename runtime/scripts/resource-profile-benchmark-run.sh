#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

image=${1:?usage: resource-profile-benchmark-run.sh IMAGE DISPLAY_PROFILE RESOURCE_PROFILE REPETITION CPU_LIMIT MEMORY_LIMIT SETTLE_SECONDS LAUNCH_REPETITIONS ENCODER_SECONDS}
display_profile=${2:?}
resource_profile=${3:?}
repetition=${4:?}
cpu_limit=${5:?}
memory_limit=${6:?}
settle=${7:?}
launch_repetitions=${8:?}
encoder_seconds=${9:?}
process_output=${ROYD_RESOURCE_BENCHMARK_PROCESS_OUTPUT:-}

safe_profile=$(printf '%s' "$resource_profile" | tr -c 'A-Za-z0-9_.-' '_')
container="royd-resource-benchmark-${safe_profile}-${repetition}-$$"
volume="${container}-data"
capture=/data/local/tmp/royd-resource-benchmark.mp4

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker volume rm "$volume" >/dev/null 2>&1 || true
}
trap cleanup EXIT HUP INT TERM
cleanup

command -v docker >/dev/null 2>&1 || {
  printf '%s\n' 'error: docker is required for a resource-profile benchmark' >&2
  exit 1
}

profile_args=$(ROYD_RESOURCE_PROFILE="$resource_profile" "$script_dir/profile.sh" "$display_profile")
display_width=$(printf '%s\n' "$profile_args" | sed -n 's/^royd.width=//p')
display_height=$(printf '%s\n' "$profile_args" | sed -n 's/^royd.height=//p')
security_mode=${ROYD_SECURITY_MODE:-privileged}
security_args=$("$script_dir/security-args.sh" "$security_mode")
container_args=$("$script_dir/container-args.sh")
runtime_arch=${ROYD_ARCH:-${ROYD_QUALIFY_ARCH:-x86_64}}
graphics_backend=${ROYD_GRAPHICS_BACKEND:-software}
gpu_args=$(ROYD_GRAPHICS_ARCH="$runtime_arch" "$script_dir/gpu-args.sh" "$graphics_backend" "$runtime_arch")
timeout=${ROYD_BOOT_TIMEOUT:-180}

capture_process_rss() {
  phase=$1
  [ -n "$process_output" ] || return 0
  process_list=$(docker exec "$container" ps -A -o PID,RSS,NAME) || {
    printf 'error: could not capture the %s process RSS snapshot\n' "$phase" >&2
    exit 1
  }
  process_rows=$(printf '%s\n' "$process_list" | awk -v profile="$resource_profile" \
    -v repetition="$repetition" -v phase="$phase" '
      $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ {
        printf "%s\t%s\t%s\t%s\t%s\t%s\n", profile, repetition, phase, $1, $2, $3
      }
    ')
  [ -n "$process_rows" ] || {
    printf 'error: the %s process RSS snapshot was empty\n' "$phase" >&2
    exit 1
  }
  printf '%s\n' "$process_rows" >>"$process_output"
}

docker volume create "$volume" >/dev/null
started_ms=$(date +%s%3N)
# Word splitting is intentional because the helper scripts emit trusted arguments.
# shellcheck disable=SC2086
docker run -d $security_args $gpu_args $container_args \
  --name "$container" \
  --cpus "$cpu_limit" \
  --memory "$memory_limit" \
  --memory-swap "$memory_limit" \
  -v "$volume:/data" \
  "$image" $profile_args >/dev/null

"$script_dir/wait-for-boot.sh" "$container" "$timeout" >&2
ROYD_RESOURCE_PROFILE="$resource_profile" \
  "$script_dir/assert-runtime.sh" "$container" >&2
docker exec "$container" input keyevent 82 >/dev/null 2>&1 || true
docker exec "$container" am start -W -a android.intent.action.MAIN \
  -c android.intent.category.HOME >/dev/null
home_ms=$(date +%s%3N)
boot_home_ms=$((home_ms - started_ms))

[ "$settle" -eq 0 ] || sleep "$settle"
settled_bytes=$(docker exec "$container" cat /sys/fs/cgroup/memory.current | tr -d '\r[:space:]')
capture_process_rss settled
cpu_before=$(docker exec "$container" sed -n 's/^usage_usec //p' /sys/fs/cgroup/cpu.stat | tr -d '\r[:space:]')

launch_sum=0
launch_samples=
iteration=1
while [ "$iteration" -le "$launch_repetitions" ]; do
  docker exec "$container" am force-stop com.android.settings >/dev/null
  if [ "$iteration" -eq "$launch_repetitions" ]; then
    docker exec "$container" dumpsys gfxinfo com.android.settings reset >/dev/null 2>&1 || true
  fi
  launch_output=$(docker exec "$container" am start -W \
    -n com.android.settings/.Settings)
  launch_ms=$(printf '%s\n' "$launch_output" | sed -n 's/^TotalTime: //p' | tail -n 1 | tr -d '\r[:space:]')
  case "$launch_ms" in
    ''|*[!0-9]*)
      printf '%s\n' 'error: Settings launch did not report TotalTime' >&2
      exit 1
      ;;
  esac
  launch_sum=$((launch_sum + launch_ms))
  if [ -n "$launch_samples" ]; then
    launch_samples="$launch_samples,$launch_ms"
  else
    launch_samples=$launch_ms
  fi
  iteration=$((iteration + 1))
done
launch_mean_ms=$((launch_sum / launch_repetitions))

for direction in up down up down; do
  case "$direction" in
    up) docker exec "$container" input swipe 270 800 270 200 400 >/dev/null ;;
    down) docker exec "$container" input swipe 270 200 270 800 400 >/dev/null ;;
  esac
done
sleep 1
gfxinfo=$(docker exec "$container" dumpsys gfxinfo com.android.settings)
frames=$(printf '%s\n' "$gfxinfo" | sed -n 's/^Total frames rendered: //p' | head -n 1 | tr -d '\r[:space:]')
janky_line=$(printf '%s\n' "$gfxinfo" | sed -n 's/^Janky frames: //p' | head -n 1)
janky_frames=$(printf '%s\n' "$janky_line" | awk '{print $1}')
janky_percent=$(printf '%s\n' "$janky_line" | sed -n 's/^[0-9][0-9]* (\([0-9.][0-9.]*\)%).*/\1/p')
frame_p50_ms=$(printf '%s\n' "$gfxinfo" | sed -n 's/^50th percentile: \([0-9][0-9]*\)ms$/\1/p' | head -n 1)
frame_p90_ms=$(printf '%s\n' "$gfxinfo" | sed -n 's/^90th percentile: \([0-9][0-9]*\)ms$/\1/p' | head -n 1)
for value in "$frames" "$janky_frames" "$janky_percent" "$frame_p50_ms" "$frame_p90_ms"; do
  [ -n "$value" ] || {
    printf '%s\n' 'error: Settings gfxinfo did not contain the expected frame metrics' >&2
    exit 1
  }
done

docker exec "$container" rm -f "$capture"
encoder_started_ms=$(date +%s%3N)
docker exec "$container" screenrecord --display-id 0 \
  --size "${display_width}x${display_height}" \
  --time-limit "$encoder_seconds" "$capture" >/dev/null 2>&1
encoder_ended_ms=$(date +%s%3N)
encoder_wall_ms=$((encoder_ended_ms - encoder_started_ms))
encoder_bytes=$(docker exec "$container" wc -c "$capture" | awk '{print $1}')
capture_process_rss post-workload

cpu_after=$(docker exec "$container" sed -n 's/^usage_usec //p' /sys/fs/cgroup/cpu.stat | tr -d '\r[:space:]')
cpu_workload_usec=$((cpu_after - cpu_before))
peak_bytes=$(docker exec "$container" cat /sys/fs/cgroup/memory.peak | tr -d '\r[:space:]')
oom_kills=$(docker exec "$container" sed -n 's/^oom_kill //p' /sys/fs/cgroup/memory.events | tr -d '\r[:space:]')
[ "${oom_kills:-0}" -eq 0 ] || {
  printf 'error: benchmark container recorded %s OOM kills\n' "$oom_kills" >&2
  exit 1
}

printf '%s\t%s\tpassed\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$resource_profile" "$repetition" "$boot_home_ms" "$launch_mean_ms" \
  "$launch_samples" "$frames" "$janky_frames" "$janky_percent" "$frame_p50_ms" \
  "$frame_p90_ms" "$encoder_wall_ms" "$encoder_bytes" "$cpu_workload_usec" \
  "$settled_bytes" "$peak_bytes"
