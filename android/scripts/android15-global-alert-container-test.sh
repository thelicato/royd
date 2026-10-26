#!/bin/sh
set -eu
ulimit -c 0
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
patch=$root/android/patches/android-15.0.0_r36/0070-netd-sample-container-global-byte-alert.patch
alert_tmp=$(mktemp -d)
trap 'rm -rf "$alert_tmp"' EXIT HUP INT TERM
for name in RoydGlobalAlert.h RoydGlobalAlertSource.h; do
 awk -v target="+++ b/system/netd/server/$name" '
  /^diff --git / {copy=0}
  $0 == target {copy=1; next}
  copy && /^\+[^+]/ {print substr($0,2)}
  copy && $0 == "+" {print ""}
 ' "$patch" >"$alert_tmp/$name"
 test -s "$alert_tmp/$name"
 if [ -n "${ROYD_ANDROID15_ALERT_SOURCE:-}" ]; then
  cmp "$alert_tmp/$name" "$ROYD_ANDROID15_ALERT_SOURCE/system/netd/server/$name"
 fi
done
${CXX:-c++} -std=c++17 -O2 -Wall -Wextra -Werror -fno-exceptions -fno-rtti -pthread \
 -I"$alert_tmp" "$root/android/tests/global-alert-native.cpp" -o "$alert_tmp/native"
timeout 20 "$alert_tmp/native"
# Reuse the real accounting syscall mock, adding object IDs for source identity.
awk '/^int main\(\)/ {exit} {print} /m->max_entries = / {print "            m->id = a->info.bpf_fd + 1000;"}' \
 "$root/android/tests/interface-accounting-native.cpp" >"$alert_tmp/accounting-mock.inc"
accounting_patch=$root/android/patches/android-15.0.0_r36/0065-netd-account-container-interface-ip-traffic.patch
awk '
 /^diff --git / {copy=0}
 $0 == "+++ b/system/netd/server/RoydInterfaceAccounting.h" {copy=1; next}
 copy && /^\+[^+]/ {print substr($0,2)}
 copy && $0 == "+" {print ""}
' "$accounting_patch" >"$alert_tmp/RoydInterfaceAccounting.h"
mkdir -p "$alert_tmp/fix/system/netd/server"
cp "$alert_tmp/RoydInterfaceAccounting.h" "$alert_tmp/fix/system/netd/server/"
awk '
 /^diff --git / {copy=($0 == "diff --git a/system/netd/server/RoydInterfaceAccounting.h b/system/netd/server/RoydInterfaceAccounting.h")}
 copy {print}
' "$root/android/patches/android-15.0.0_r36/0066-netd-separate-container-accounting-error-latch.patch" \
 | patch -s --fuzz=0 -p1 -d "$alert_tmp/fix"
cp "$alert_tmp/fix/system/netd/server/RoydInterfaceAccounting.h" "$alert_tmp/RoydInterfaceAccounting.h"
${CXX:-c++} -std=c++17 -O2 -Wall -Wextra -Werror -fno-exceptions -fno-rtti -pthread \
 -I"$alert_tmp" -I"$root/android/tests/interface-accounting-stubs" \
 "$root/android/tests/global-alert-source.cpp" -o "$alert_tmp/source"
"$alert_tmp/source"
python3 "$root/android/tests/global-alert-controller.py" "$root" "$alert_tmp"
${CXX:-c++} -std=c++17 -O2 -Wall -Wextra -Werror -fno-exceptions -fno-rtti -pthread \
 "$alert_tmp/entry-points.cpp" -o "$alert_tmp/entry-points"
"$alert_tmp/entry-points"
# Both production entry points preserve the original locked permission checks.
! grep -Eq '^[-+].*(NETD_LOCKING_RPC|PERM_NETWORK_STACK|PERM_MAINLINE_NETWORK_STACK)' "$patch"
! grep -Eq '^[-+].*(setInterfaceQuota|setInterfaceAlert|setCostlyAlert|enableDataSaver)' "$patch"
! grep -Eq '^[-+].*(BPF_MAP_UPDATE_ELEM|TCX|BPF_LINK_CREATE|iptablesRestoreFunction)' "$patch"
grep -Fq '+        return result == -ENOENT ? -1 : result;' "$patch"
grep -Fq '+    if (royd::enabled()) {' "$patch"
# The shared strict gate is exercised by the existing applied accounting contract.
printf '%s\n' 'Android 15 sampled global byte-alert contracts passed'
