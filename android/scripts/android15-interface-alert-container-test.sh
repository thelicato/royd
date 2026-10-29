#!/bin/sh
set -eu
ulimit -c 0
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
patch_file=$root/android/patches/android-15.0.0_r36/0075-netd-notify-container-interface-byte-alerts.patch
for name in RoydInterfaceAlert.h RoydInterfaceAlertSource.h; do
 awk -v target="+++ b/system/netd/server/$name" '
  /^diff --git / {copy=0}
  $0 == target {copy=1; next}
  copy && /^\+[^+]/ {print substr($0,2)}
  copy && $0 == "+" {print ""}
 ' "$patch_file" >"$tmp/$name"
 test -s "$tmp/$name"
 if [ -n "${ROYD_ANDROID15_INTERFACE_ALERT_SOURCE:-}" ]; then
  cmp "$tmp/$name" "$ROYD_ANDROID15_INTERFACE_ALERT_SOURCE/system/netd/server/$name"
 fi
done
${CXX:-c++} -std=c++17 -O2 -Wall -Wextra -Werror -fno-exceptions -fno-rtti -pthread \
 -I"$tmp" "$root/android/tests/interface-alert-native.cpp" -o "$tmp/native"
timeout 20 "$tmp/native"
python3 "$root/android/tests/interface-alert-controller.py" "$root" "$tmp"
# Reuse the exact applied quota header and syscall mock, not a parallel source model.
awk '/^int main\(\)/ {exit} {print}' "$root/android/tests/interface-quota-native.cpp" >"$tmp/quota-mock.inc"
: >"$tmp/RoydInterfaceAccounting.h"
cp "$tmp/applied/system/netd/server/RoydInterfaceQuota.h" "$tmp/"
${CXX:-c++} -std=c++17 -O2 -Wall -Wextra -Werror -fno-exceptions -fno-rtti -pthread \
 -I"$tmp" "$root/android/tests/interface-alert-source.cpp" -o "$tmp/source"
timeout 10 "$tmp/source"
if [ -n "${ROYD_ANDROID15_INTERFACE_ALERT_SOURCE:-}" ]; then
 for name in BandwidthController.h RoydInterfaceQuota.h; do
  cmp "$tmp/applied/system/netd/server/$name" "$ROYD_ANDROID15_INTERFACE_ALERT_SOURCE/system/netd/server/$name"
 done
 python3 - "$tmp/applied/system/netd/server/BandwidthController.cpp" \
  "$ROYD_ANDROID15_INTERFACE_ALERT_SOURCE/system/netd/server/BandwidthController.cpp" <<'PY'
from pathlib import Path
import sys
fixture, actual = [Path(p).read_text() for p in sys.argv[1:]]
for name in ['BandwidthController::BandwidthController(', 'BandwidthController::dumpRoydGlobalAlert(',
             'BandwidthController::enableBandwidthControl(', 'BandwidthController::setInterfaceQuota(',
             'BandwidthController::getInterfaceQuota(', 'BandwidthController::removeInterfaceQuota(',
             'BandwidthController::setInterfaceAlert(', 'BandwidthController::removeInterfaceAlert(']:
    def method(text):
        start = text.index(name)
        end = text.index('{', start)
        depth = 1
        for i in range(end+1, len(text)):
            depth += (text[i] == '{') - (text[i] == '}')
            if not depth: return text[start:i+1]
        raise AssertionError(name)
    assert method(fixture) == method(actual), name
PY
fi
printf '%s\n' 'Android 15 associated interface-alert contracts passed'
