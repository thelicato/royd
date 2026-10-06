#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
patch="$root/android/patches/android-15.0.0_r36/0015-connectivity-tolerate-missing-pf-key-rcu.patch"

[ -f "$patch" ] || { echo 'missing Android 15 royd network-stats RCU patch' >&2; exit 1; }
[ "$(grep -c '^diff --git a/packages/modules/Connectivity/service/src/com/android/server/BpfNetMaps.java' "$patch")" -eq 1 ]
[ "$(grep -c '^diff --git ' "$patch")" -eq 1 ]
grep -F 'import static android.system.OsConstants.EAFNOSUPPORT;' "$patch" >/dev/null
grep -F 'private static boolean isRoydContainerWithoutSelinux() {' "$patch" >/dev/null
grep -F 'private static volatile boolean sRoydKernelRcuUnavailable = false;' "$patch" >/dev/null
grep -F '"1".equals(System.getenv("ROYD_CONTAINER"))' "$patch" >/dev/null
grep -F '!new File("/sys/fs/selinux/enforce").exists();' "$patch" >/dev/null
grep -F 'final int probeErr = mDeps.synchronizeKernelRCU();' "$patch" >/dev/null
grep -F 'if (probeErr == -EAFNOSUPPORT) {' "$patch" >/dev/null
grep -F 'sRoydKernelRcuUnavailable = true;' "$patch" >/dev/null
grep -F 'ROYD: leaving the active network stats map unchanged because' "$patch" >/dev/null
grep -F 'maybeThrow(probeErr, "synchronizeKernelRCU probe failed");' "$patch" >/dev/null

# The fallback must return before changing or clearing either stats map. Stock map swapping and
# its post-swap barrier must remain untouched for supported kernels and every non-container run.
probe_line=$(grep -n 'final int probeErr = mDeps.synchronizeKernelRCU();' "$patch" | cut -d: -f1)
update_line=$(grep -n 'sConfigurationMap.updateEntry(CURRENT_STATS_MAP_CONFIGURATION_KEY,' "$patch" | cut -d: -f1)
[ "$probe_line" -lt "$update_line" ] || {
  echo 'network-stats RCU probe does not precede the active-map update' >&2
  exit 1
}
if grep -Eq '^[+-].*(sConfigurationMap\.getValue|sConfigurationMap\.updateEntry|final int err = mDeps\.synchronizeKernelRCU|maybeThrow\(err, "synchronizeKernelRCU failed")' "$patch"; then
  echo 'network-stats RCU patch changes the stock map swap or post-swap barrier' >&2
  exit 1
fi

if grep -Fq 'ROYD_DIAG' "$patch"; then
  echo 'permanent network-stats RCU patch retains a diagnostic-only marker' >&2
  exit 1
fi

printf '%s\n' 'Android 15 network-stats RCU container contract passed'
