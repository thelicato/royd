#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
patch=$root/android/patches/android-15.0.0_r36/0067-connectivity-use-container-packet-rcu-barrier.patch
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
header=packages/modules/Connectivity/staticlibs/native/bpfmapjni/RoydNetworkStatsRcu.h
awk -v target="+++ b/$header" '
  /^diff --git / {copy=0}
  $0 == target {copy=1; next}
  copy && /^\+[^+]/ {print substr($0,2)}
  copy && $0 == "+" {print ""}
' "$patch" >"$tmp/RoydNetworkStatsRcu.h"
test -s "$tmp/RoydNetworkStatsRcu.h"
${CXX:-c++} -std=c++17 -O2 -Wall -Wextra -Werror -pthread \
  -I"$tmp" -I"$root/android/tests/rcu-stubs" "$root/android/tests/rcu-packet-native.cpp" -o "$tmp/native"
"$tmp/native"
if [ -n "${ROYD_ANDROID15_RCU_SOURCE:-}" ]; then
  cmp "$tmp/RoydNetworkStatsRcu.h" "$ROYD_ANDROID15_RCU_SOURCE/$header"
  if [ -n "${ROYD_TEST_JAVA_HOME:-}" ]; then
    python3 "$root/android/tests/rcu-java-contract.py" "$ROYD_ANDROID15_RCU_SOURCE" "$tmp" "$ROYD_TEST_JAVA_HOME"
  fi
fi
# Append-only replacement must remove the frozen-selector success path.
grep -Fq -- '-    private static volatile boolean sRoydKernelRcuUnavailable = false;' "$patch"
grep -Fq -- '-            if (sRoydKernelRcuUnavailable) return;' "$patch"
! grep -Eq '^[-+].*(sConfigurationMap\.updateEntry|final int err = mDeps.synchronizeKernelRCU|maybeThrow\(err, "synchronizeKernelRCU failed")' "$patch"
printf '%s\n' 'Android 15 packet-socket RCU contract passed'
