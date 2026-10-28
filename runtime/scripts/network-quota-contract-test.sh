#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
export PYTHONDONTWRITEBYTECODE=1
sh -n "$root/runtime/scripts/network-quota-test.sh" "$root/runtime/scripts/network-netd-probe-build.sh"
python3 -m unittest discover -s "$root/runtime/tests/network-quota" -p '*_test.py'
# Optional real SDK/core/AIDL compilation, without Docker or Android boot.
tree=${ROYD_QUOTA_TEST_ANDROID_TREE:-}
if [ -z "$tree" ] && [ -f "$root/.work/android-src-15/out/host/linux-x86/bin/d8" ]; then
  tree=$root/.work/android-src-15
fi
if [ -n "$tree" ]; then
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT HUP INT TERM
  export ROYD_ANDROID_TEST_TREE="$tree"
  export ROYD_ANDROID_TEST_SYSTEM_MODULES="$tree/out/soong/.intermediates/libcore/core-all-system-modules/android_common/system"
  "$root/runtime/scripts/network-netd-probe-build.sh" "$tmp/control" "$root/runtime/tests/network-alert/QuotaControlProbe.java"
  ROYD_NETWORK_DNS_POLICY=1 "$root/runtime/scripts/network-dns-build.sh" "$tmp/apps"
  printf '%s\n' 'Quota controller and ordinary workers compiled against Android core/SDK and stock netd AIDL'
else
  printf '%s\n' 'Android compilation not run: set ROYD_QUOTA_TEST_ANDROID_TREE to a built Android 15 tree'
fi
printf '%s\n' 'Finite interface-quota packet/evidence/ownership contracts passed'
