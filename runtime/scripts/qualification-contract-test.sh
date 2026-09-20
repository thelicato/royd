#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
# shellcheck disable=SC1091
. "$script_dir/runtime-result-lib.sh"
# shellcheck disable=SC1091
. "$script_dir/binder-identity-lib.sh"

tmp=$(mktemp -d)
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT INT TERM

key=$(runtime_result_key 15 x86_64 standard graphical privileged)
[ "$key" = '15/x86_64-standard-graphical-privileged.env' ]
file="$tmp/runtime-results/$key"
runtime_result_write "$file" \
  'RESULT_FORMAT=3' \
  'ANDROID_VERSION=15' \
  'ARCH=x86_64' \
  'IMAGE_PROFILE=standard' \
  'PROFILE_POLICY=standard-v1' \
  'PROFILE_POLICY_SHA256=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855' \
  'HAL_PROFILE=graphical' \
  'SECURITY_MODE=privileged' \
  'SECURITY_PROFILE=privileged-v1' \
  'SECURITY_PROFILE_SHA256=placeholder' \
  'HOST_STATUS=pass' \
  'IMAGE_STATUS=pass' \
  'BOOT_STATUS=pass' \
  'HEALTH_STATUS=pass' \
  'RUNTIME_STATUS=pass' \
  'SECURITY_STATUS=pass' \
  'SECURITY_EVIDENCE_STATUS=pass' \
  'GRAPHICS_STATUS=pass' \
  'LOGS_STATUS=pass' \
  'ADB_STATUS=pass' \
  'BINDER_ISOLATION_STATUS=pass' \
  'RESULT_STATUS=pass'
[ "$(runtime_result_get "$file" RESULT_STATUS)" = pass ]

report="$tmp/runtime.md"
ROYD_RUNTIME_RESULTS_DIR="$tmp/runtime-results" ROYD_RUNTIME_REPORT_OUTPUT="$report" "$script_dir/qualification-report.sh" >/dev/null
grep -Fq '| 15 | x86_64 | pass | pass | pass | pass | pass | pass | pass | pass | pass | pass | pass | pass |' "$report"

grep -Fq 'royd-binder-info' "$repo_root/android/royd/vendor/royd/Android.bp"
grep -Fq 'royd-binder-info' "$repo_root/android/royd/vendor/royd/royd.mk"

identity_a='/dev/binderfs/binder-control=100
/dev/binder=101
/dev/hwbinder=102
/dev/vndbinder=103'
identity_b='/dev/binderfs/binder-control=200
/dev/binder=201
/dev/hwbinder=202
/dev/vndbinder=203'
binder_identities_isolated "$identity_a" "$identity_b"
if binder_identities_isolated "$identity_a" "$identity_a"; then
  printf '%s\n' 'error: Binder identity comparison accepted shared device identities' >&2
  exit 1
fi

cc=${CC:-cc}
"$cc" -std=c11 -Wall -Wextra -Werror \
  "$repo_root/android/royd/vendor/royd/binder_info/royd-binder-info.c" \
  -o "$tmp/royd-binder-info"
"$tmp/royd-binder-info" /dev/null /dev/zero > "$tmp/binder-info.out"
grep -Fq '/dev/null=' "$tmp/binder-info.out"
grep -Fq '/dev/zero=' "$tmp/binder-info.out"

[ "$(ROYD_HAL_PROFILE=graphical "$script_dir/default-runtime-profile.sh")" = default ]
[ "$(ROYD_HAL_PROFILE=headless "$script_dir/default-runtime-profile.sh")" = headless ]

printf '%s\n' 'Runtime qualification contract test passed'
