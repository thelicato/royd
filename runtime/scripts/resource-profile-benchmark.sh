#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
default_image=$("$script_dir/default-image.sh" standard x86_64)
image=${1:-${ROYD_IMAGE:-$default_image}}
display_profile=${ROYD_PROFILE:-$("$script_dir/default-runtime-profile.sh")}
resource_profiles=${ROYD_RESOURCE_BENCHMARK_PROFILES:-'low-memory performance'}
repetitions=${ROYD_RESOURCE_BENCHMARK_REPETITIONS:-3}
cpu_limit=${ROYD_RESOURCE_BENCHMARK_CPUS:-4}
memory_limit=${ROYD_RESOURCE_BENCHMARK_MEMORY:-4g}
settle=${ROYD_RESOURCE_BENCHMARK_SETTLE:-10}
launch_repetitions=${ROYD_RESOURCE_BENCHMARK_LAUNCHES:-5}
encoder_seconds=${ROYD_RESOURCE_BENCHMARK_ENCODER_SECONDS:-3}
output=${ROYD_RESOURCE_BENCHMARK_OUTPUT:--}
runner=${ROYD_RESOURCE_BENCHMARK_RUNNER:-$script_dir/resource-profile-benchmark-run.sh}
provenance_runner=${ROYD_RESOURCE_BENCHMARK_PROVENANCE_RUNNER:-$script_dir/memory-provenance.sh}
workdir=$(mktemp -d)
status=0

cleanup() {
  rm -rf "$workdir"
}
trap cleanup EXIT HUP INT TERM

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

positive_integer ROYD_RESOURCE_BENCHMARK_REPETITIONS "$repetitions"
positive_integer ROYD_RESOURCE_BENCHMARK_CPUS "$cpu_limit"
positive_integer ROYD_RESOURCE_BENCHMARK_LAUNCHES "$launch_repetitions"
positive_integer ROYD_RESOURCE_BENCHMARK_ENCODER_SECONDS "$encoder_seconds"
case "$settle" in
  ''|*[!0-9]*)
    printf 'error: ROYD_RESOURCE_BENCHMARK_SETTLE must be a whole number: %s\n' "$settle" >&2
    exit 2
    ;;
esac
case "$memory_limit" in
  *[!0-9kKmMgG]*|'')
    printf 'error: invalid benchmark memory limit: %s\n' "$memory_limit" >&2
    exit 2
    ;;
esac

"$script_dir/profile.sh" "$display_profile" >/dev/null
for resource_profile in $resource_profiles; do
  "$script_dir/resource-profile.sh" "$resource_profile" >/dev/null
done

common_provenance=$(ROYD_RESOURCE_PROFILE=low-memory \
  "$provenance_runner" "$image" "$display_profile" | \
  sed '/^- runtime resource profile:/d')
host_kernel=$(uname -srmo)
host_cpu_model=$(sed -n 's/^model name[[:space:]]*: //p' /proc/cpuinfo | head -n 1)
[ -n "$host_cpu_model" ] || host_cpu_model=unavailable
host_logical_cpus=$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf unavailable)
host_memory_kib=$(sed -n 's/^MemTotal:[[:space:]]*\([0-9][0-9]*\) kB$/\1/p' /proc/meminfo)
[ -n "$host_memory_kib" ] || host_memory_kib=unavailable
if command -v docker >/dev/null 2>&1; then
  docker_version=$(docker version --format '{{.Server.Version}}' 2>/dev/null || printf unavailable)
else
  docker_version=unavailable
fi

results="$workdir/results.tsv"
printf 'profile\trepetition\tstatus\tboot_home_ms\tlaunch_mean_ms\tlaunch_samples_ms\tframes\tjanky_frames\tjanky_percent\tframe_p50_ms\tframe_p90_ms\tencoder_wall_ms\tencoder_bytes\tcpu_workload_usec\tsettled_bytes\tpeak_bytes\n' >"$results"

repetition=1
while [ "$repetition" -le "$repetitions" ]; do
  for resource_profile in $resource_profiles; do
    log="$workdir/${resource_profile}-${repetition}.log"
    printf 'Benchmarking resource profile %s, repetition %s/%s\n' \
      "$resource_profile" "$repetition" "$repetitions" >&2
    set +e
    row=$("$runner" "$image" "$display_profile" "$resource_profile" "$repetition" \
      "$cpu_limit" "$memory_limit" "$settle" "$launch_repetitions" \
      "$encoder_seconds" 2>"$log")
    run_status=$?
    set -e
    if [ "$run_status" -eq 0 ]; then
      printf '%s\n' "$row" >>"$results"
    else
      status=1
      printf '%s\t%s\tfailed\tunavailable\tunavailable\tunavailable\tunavailable\tunavailable\tunavailable\tunavailable\tunavailable\tunavailable\tunavailable\tunavailable\tunavailable\tunavailable\n' \
        "$resource_profile" "$repetition" >>"$results"
    fi
  done
  repetition=$((repetition + 1))
done

report="$workdir/report.md"
{
  printf '# royd resource-profile benchmark\n\n'
  printf 'This report compares resource profiles from the same image on the same host. Each row uses a fresh `/data` volume. Performance mode is not considered faster unless repeated workload measurements demonstrate it.\n\n'
  printf '%s\n' "$common_provenance"
  printf -- '- host kernel: `%s`\n' "$host_kernel"
  printf -- '- host CPU: `%s`\n' "$host_cpu_model"
  printf -- '- host logical CPUs: `%s`\n' "$host_logical_cpus"
  printf -- '- host memory: `%s KiB`\n' "$host_memory_kib"
  printf -- '- Docker Engine: `%s`\n' "$docker_version"
  printf -- '- resource profiles: `%s`\n' "$resource_profiles"
  printf -- '- repetitions per profile: `%s`\n' "$repetitions"
  printf -- '- CPU limit: `%s`\n' "$cpu_limit"
  printf -- '- memory and swap limit: `%s`\n' "$memory_limit"
  printf -- '- pre-workload settle time: `%s seconds`\n' "$settle"
  printf -- '- cold Settings launches per repetition: `%s`\n' "$launch_repetitions"
  printf -- '- screenrecord duration: `%s seconds`\n\n' "$encoder_seconds"
  printf 'The named workload boots to Home, performs repeated force-stop plus cold Settings launches, scrolls Settings to collect `gfxinfo`, and completes a software `screenrecord`. CPU time covers the launch, scroll and recording phase. The recording wall time and output size are health indicators, not an unconstrained encoder-throughput score.\n\n'
  printf '## Summary\n\n'
  printf '| Resource profile | Passed | Mean boot-to-Home (ms) | Mean Settings launch (ms) | Mean frame p90 (ms) | Mean janky frames (%%) | Mean workload CPU (ms) | Mean settled memory (MiB) | Mean peak memory (MiB) |\n'
  printf '| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |\n'
  for resource_profile in $resource_profiles; do
    awk -F '\t' -v profile="$resource_profile" '
      NR > 1 && $1 == profile && $3 == "passed" {
        count++; boot += $4; launch += $5; p90 += $11; janky += $9;
        cpu += $14 / 1000; settled += $15 / 1048576; peak += $16 / 1048576
      }
      END {
        if (count == 0) {
          printf "| `%s` | 0 | unavailable | unavailable | unavailable | unavailable | unavailable | unavailable | unavailable |\n", profile
        } else {
          printf "| `%s` | %d | %.0f | %.0f | %.1f | %.2f | %.0f | %.1f | %.1f |\n", profile, count, boot/count, launch/count, p90/count, janky/count, cpu/count, settled/count, peak/count
        }
      }
    ' "$results"
  done
  printf '\n## Individual repetitions\n\n'
  printf '| Profile | Repetition | Result | Boot-to-Home (ms) | Mean launch (ms) | Launch samples (ms) | Frames | Janky | Janky (%%) | p50 (ms) | p90 (ms) | Encoder wall (ms) | Encoder bytes | CPU (usec) | Settled bytes | Peak bytes |\n'
  printf '| --- | ---: | --- | ---: | ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |\n'
  tail -n +2 "$results" | while IFS="$(printf '\t')" read -r resource_profile run status_value boot launch samples frames janky janky_percent p50 p90 encoder_wall encoder_bytes cpu settled_bytes peak_bytes; do
    printf '| `%s` | %s | %s | %s | %s | `%s` | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n' \
      "$resource_profile" "$run" "$status_value" "$boot" "$launch" "$samples" \
      "$frames" "$janky" "$janky_percent" "$p50" "$p90" "$encoder_wall" \
      "$encoder_bytes" "$cpu" "$settled_bytes" "$peak_bytes"
  done
  if [ "$status" -ne 0 ]; then
    printf '\n## Failure diagnostics\n\n'
    for log in "$workdir"/*.log; do
      [ -s "$log" ] || continue
      printf '### `%s`\n\n```text\n' "${log##*/}"
      tail -n 80 "$log"
      printf '```\n\n'
    done
  fi
  printf '\n## Interpretation\n\n'
  printf 'Compare the repeated rows rather than a single minimum. Differences smaller than run-to-run variation are inconclusive. This local result does not establish a cross-host performance claim.\n'
} >"$report"

if [ "$output" = '-' ]; then
  cat "$report"
else
  mkdir -p "$(dirname -- "$output")"
  cp "$report" "$output"
  raw_output=${output%.md}.tsv
  [ "$raw_output" != "$output" ] || raw_output="$output.tsv"
  cp "$results" "$raw_output"
  printf 'Wrote resource-profile benchmark to %s\n' "$output"
  printf 'Wrote raw resource-profile measurements to %s\n' "$raw_output"
fi

exit "$status"
