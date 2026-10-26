#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
sh -n "$root/runtime/scripts/network-alert-build.sh" "$root/runtime/scripts/network-alert-test.sh"
export PYTHONDONTWRITEBYTECODE=1
python3 "$root/runtime/tests/network-alert/assess_alert_test.py"
python3 "$root/runtime/tests/network-alert/runner_test.py"
# Use real generated AIDL and Android core modules when an applied tree exists.
tree=${ROYD_ANDROID_TEST_TREE:-$root/.work/android-src-15}
if [ -f "$tree/out/soong/.intermediates/packages/modules/Connectivity/staticlibs/netd/netd_aidl_interface-V15-java/android_common/javac/netd_aidl_interface-V15-java.jar" ] &&
   [ -f "$tree/out/soong/.intermediates/libcore/core-all-system-modules/android_common/system/lib/modules" ]; then
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  "$root/runtime/scripts/network-alert-build.sh" "$tmp/build"
  test -s "$tmp/build/dex/classes.dex"
  printf '%s\n' 'Real Android core/AIDL global-alert helper compilation passed'
else
  printf '%s\n' 'Android global-alert helper compilation not checked: applied core/AIDL inputs unavailable'
fi
printf '%s\n' 'Global-alert receipt, evidence and ownership contracts passed'
