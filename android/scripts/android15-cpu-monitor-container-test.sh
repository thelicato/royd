#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
patch="$root/android/patches/android-15.0.0_r36/0028-framework-skip-container-cpu-monitor-without-cpufreq.patch"

[ -f "$patch" ] || { echo 'missing Android 15 container CPU-monitor patch' >&2; exit 1; }
[ "$(grep -c '^diff --git a/frameworks/base/services/core/java/com/android/server/cpu/CpuMonitorService.java' "$patch")" -eq 1 ]
[ "$(grep -c '^diff --git ' "$patch")" -eq 1 ]
grep -F '+import android.os.SELinux;' "$patch" >/dev/null
grep -F 'private static boolean shouldSkipRoydCpuMonitor() {' "$patch" >/dev/null
grep -F '!"1".equals(System.getenv("ROYD_CONTAINER")) || SELinux.isSELinuxEnabled()' "$patch" >/dev/null
grep -F 'new File("/sys/devices/system/cpu/cpufreq").listFiles(' "$patch" >/dev/null
grep -F 'file.isDirectory() && file.getName().startsWith("policy")' "$patch" >/dev/null
grep -F 'return policyDirs == null || policyDirs.length == 0;' "$patch" >/dev/null
grep -F 'ROYD: CPU frequency policies unavailable; CPU monitor disabled' "$patch" >/dev/null

# Only the explicitly gated missing-capability path may bypass startup. Keep the reader's stock
# initialisation, fatal diagnostic and service publication unchanged for every other environment.
grep -F 'if (!mCpuInfoReader.init() || mCpuInfoReader.readCpuInfos() == null) {' "$patch" >/dev/null
grep -F 'Slogf.wtf(TAG, "Failed to initialize CPU info reader.' "$patch" >/dev/null
if grep -Eq '^-.*(mCpuInfoReader\.init|readCpuInfos|Slogf\.wtf|publishLocalService|publishBinderService)' "$patch"; then
  echo 'CPU-monitor patch changes the stock startup or failure path' >&2
  exit 1
fi

printf '%s\n' 'Android 15 unavailable CPU-monitor container contract passed'
