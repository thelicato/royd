#!/bin/sh
set -eu
ulimit -c 0
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
export PYTHONDONTWRITEBYTECODE=1
python3 "$root/android/tests/quota-events-fixture.py" "$root" "$tmp"
${CXX:-c++} -std=c++17 -O2 -Wall -Wextra -Werror -fno-exceptions -fno-rtti -pthread \
 -I"$tmp" "$root/android/tests/quota-events-native.cpp" -o "$tmp/native"
timeout 20 "$tmp/native"
printf '%s\n' 'Quota-event threshold, lifecycle, cancellation, faults and callback re-entry passed'
python3 "$root/android/tests/quota-events-source-mock.py" "$root" "$tmp"
${CXX:-c++} -std=c++17 -O2 -Wall -Wextra -Werror -fno-exceptions -fno-rtti -pthread \
 -I"$tmp" "$root/android/tests/quota-events-source.cpp" -o "$tmp/source"
timeout 10 "$tmp/source"
python3 "$root/android/tests/quota-events-controller.py" "$root" "$tmp"
python3 "$root/runtime/scripts/assert-quota-events-test.py"
if [ -n "${ROYD_ANDROID15_QUOTA_EVENTS_SOURCE:-}" ]; then
 for name in BandwidthController.h RoydInterfaceQuota.h RoydQuotaEvents.h RoydQuotaEventSource.h; do
  cmp "$tmp/$name" "$ROYD_ANDROID15_QUOTA_EVENTS_SOURCE/system/netd/server/$name"
 done
 python3 - "$tmp/BandwidthController.cpp" \
  "$ROYD_ANDROID15_QUOTA_EVENTS_SOURCE/system/netd/server/BandwidthController.cpp" <<'PY'
from pathlib import Path
import sys
fixture,actual=(Path(p).read_text() for p in sys.argv[1:])
for name in ['BandwidthController','dumpRoydGlobalAlert','setInterfaceQuota','removeInterfaceQuota']:
 def method(text):
  start=text.index('BandwidthController::'+name+'(');opening=text.index('{',start);depth=1
  for end in range(opening+1,len(text)):
   depth+=(text[end]=='{')-(text[end]=='}')
   if not depth:return text[start:end+1]
  raise AssertionError(name)
 assert method(fixture)==method(actual),name
PY
fi
printf '%s\n' 'Android 15 interface quota-event contracts passed'
