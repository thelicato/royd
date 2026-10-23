#!/bin/sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
output=${ROYD_NETWORK_DNS_OUTPUT_DIR:-$root/.work/network-history-$(date -u +%Y%m%dT%H%M%SZ)-$$}
case "$output" in ''|/|.|..) exit 2 ;; esac
for setting in ROYD_NETWORK_DNS_RECOVERY ROYD_NETWORK_DNS_POLICY ROYD_NETWORK_DNS_DATASAVER ROYD_NETWORK_DNS_METERED ROYD_NETWORK_DNS_SAVER_POLICY ROYD_NETWORK_METERED_SLEEP_BEFORE_LAUNCH; do
  eval 'value=${'"$setting"':-0}'
  [ "$value" = 0 ] || { printf '%s\n' 'error: history qualification requires the ordinary DNS workload'; exit 2; }
done
[ ! -e "$output" ] || { printf '%s\n' 'error: history evidence directory must be new'; exit 1; }
export ROYD_NETWORK_DNS_OUTPUT_DIR=$output
export ROYD_NETWORK_DNS_ASSERT_RUNNER=$script_dir/network-history-assert.sh
export ROYD_NETWORK_DNS_BUILD_RUNNER=$script_dir/network-history-build.sh
status=0
"$script_dir/network-dns-test.sh" "$@" || status=$?
if [ -d "$output" ]; then
  grep -Fxq WORKLOAD_EXIT_STATUS=0 "$output/history/workload.env" 2>/dev/null || status=1
  grep -Fxq RUNTIME_EXIT_STATUS=0 "$output/history/workload.env" 2>/dev/null || status=1
  result=fail
  [ "$status" -ne 0 ] || result=pass
  printf 'ROYD_NETWORK_HISTORY_EVIDENCE_FORMAT=1\nRESULT_STATUS=%s\n' "$result" >"$output/history-manifest.env"
  if [ -f "$output/history/assessment.env" ]; then
    sed -n '/^HISTORY_\(IDENTITY\|USAGE\|MONOTONIC\|ACCESS\)_STATUS=\(pass\|fail\)$/p' "$output/history/assessment.env" >>"$output/history-manifest.env"
  fi
fi
exit "$status"
