#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

cat >"$tmp/provenance" <<'SRC'
#!/bin/sh
printf '%s\n' '- image: `royd:test`'
printf '%s\n' '- image ID: `sha256:benchmark-image`'
printf '%s\n' '- runtime resource profile: `low-memory`'
SRC
chmod +x "$tmp/provenance"

cat >"$tmp/runner" <<'SRC'
#!/bin/sh
set -eu
profile=$3
repetition=$4
printf '%s\t%s\n' "$profile" "$repetition" >>"$MOCK_CALLS"
printf '%s\t%s\tsettled\t100\t%s\tsystem_server\n' \
  "$profile" "$repetition" "$((100000 + repetition))" \
  >"$ROYD_RESOURCE_BENCHMARK_PROCESS_OUTPUT"
printf '%s\t%s\tsettled\t200\t%s\tcom.android.settings\n' \
  "$profile" "$repetition" "$((50000 + repetition))" \
  >>"$ROYD_RESOURCE_BENCHMARK_PROCESS_OUTPUT"
printf '%s\t%s\tpost-workload\t100\t%s\tsystem_server\n' \
  "$profile" "$repetition" "$((101000 + repetition))" \
  >>"$ROYD_RESOURCE_BENCHMARK_PROCESS_OUTPUT"
case "$profile" in
  low-memory) offset=0 ;;
  performance) offset=100 ;;
esac
printf '%s\t%s\tpassed\t%s\t%s\t100,200\t20\t2\t10.0\t16\t32\t3100\t4096\t500000\t104857600\t209715200\n' \
  "$profile" "$repetition" "$((1000 + offset + repetition))" "$((150 + offset + repetition))"
SRC
chmod +x "$tmp/runner"

: >"$tmp/calls"
MOCK_CALLS="$tmp/calls" \
ROYD_RESOURCE_BENCHMARK_RUNNER="$tmp/runner" \
ROYD_RESOURCE_BENCHMARK_PROVENANCE_RUNNER="$tmp/provenance" \
ROYD_RESOURCE_BENCHMARK_REPETITIONS=2 \
ROYD_RESOURCE_BENCHMARK_SETTLE=0 \
ROYD_RESOURCE_BENCHMARK_OUTPUT="$tmp/report.md" \
  "$script_dir/resource-profile-benchmark.sh" royd:test >/dev/null

[ "$(wc -l <"$tmp/calls" | tr -d ' ')" -eq 4 ]
sed -n '1p' "$tmp/calls" | grep -Fqx 'low-memory	1'
sed -n '2p' "$tmp/calls" | grep -Fqx 'performance	1'
sed -n '3p' "$tmp/calls" | grep -Fqx 'low-memory	2'
sed -n '4p' "$tmp/calls" | grep -Fqx 'performance	2'
grep -Fq '| `low-memory` | 2 |' "$tmp/report.md"
grep -Fq '| `performance` | 2 |' "$tmp/report.md"
grep -Fq '1002 [1001-1002]' "$tmp/report.md"
grep -Fq '## Settled process RSS' "$tmp/report.md"
grep -Fq 'system_server 97.7 MiB, com.android.settings 48.8 MiB' "$tmp/report.md"
grep -Fq -- '- CPU limit: `4`' "$tmp/report.md"
grep -Fq -- '- memory and swap limit: `4g`' "$tmp/report.md"
head -n 1 "$tmp/report.tsv" | grep -Fqx "$(printf 'profile\trepetition\tstatus\tboot_home_ms\tlaunch_mean_ms\tlaunch_samples_ms\tframes\tjanky_frames\tjanky_percent\tframe_p50_ms\tframe_p90_ms\tencoder_wall_ms\tencoder_bytes\tcpu_workload_usec\tsettled_bytes\tpeak_bytes')"
head -n 1 "$tmp/report.processes.tsv" | grep -Fqx "$(printf 'profile\trepetition\tphase\tpid\trss_kib\tname')"
[ "$(wc -l <"$tmp/report.processes.tsv" | tr -d ' ')" -eq 13 ]

if ROYD_RESOURCE_BENCHMARK_REPETITIONS=0 \
    ROYD_RESOURCE_BENCHMARK_RUNNER="$tmp/runner" \
    ROYD_RESOURCE_BENCHMARK_PROVENANCE_RUNNER="$tmp/provenance" \
    "$script_dir/resource-profile-benchmark.sh" royd:test >/dev/null 2>&1; then
  printf '%s\n' 'error: resource-profile benchmark accepted zero repetitions' >&2
  exit 1
fi

grep -Fq -- '--cpus "$cpu_limit"' "$script_dir/resource-profile-benchmark-run.sh"
grep -Fq -- '--memory "$memory_limit"' "$script_dir/resource-profile-benchmark-run.sh"
grep -Fq 'repetitions=${ROYD_RESOURCE_BENCHMARK_REPETITIONS:-5}' \
  "$script_dir/resource-profile-benchmark.sh"
grep -Fq 'memory.peak' "$script_dir/resource-profile-benchmark-run.sh"
grep -Fq 'cpu.stat' "$script_dir/resource-profile-benchmark-run.sh"
grep -Fq 'ps -A -o PID,RSS,NAME' "$script_dir/resource-profile-benchmark-run.sh"
grep -Fq 'dumpsys gfxinfo com.android.settings' "$script_dir/resource-profile-benchmark-run.sh"
grep -Fq 'screenrecord --display-id 0' "$script_dir/resource-profile-benchmark-run.sh"
grep -Fq -- '--size "${display_width}x${display_height}"' "$script_dir/resource-profile-benchmark-run.sh"

printf '%s\n' 'Runtime resource-profile benchmark contract test passed'
