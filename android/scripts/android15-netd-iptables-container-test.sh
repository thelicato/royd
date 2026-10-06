#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
patch="$root/android/patches/android-15.0.0_r36/0013-netd-tolerate-missing-legacy-iptables.patch"

[ -f "$patch" ] || { echo 'missing Android 15 royd netd iptables patch' >&2; exit 1; }
[ "$(grep -c '^diff --git a/system/netd/server/' "$patch")" -eq 2 ]
[ "$(grep -c '^diff --git ' "$patch")" -eq 2 ]
grep -F '+        "libselinux",' "$patch" >/dev/null
grep -F '#include <selinux/selinux.h>' "$patch" >/dev/null
grep -F 'static bool isRoydContainerWithoutSelinux() {' "$patch" >/dev/null
grep -F 'strcmp(roydContainer, "1") == 0 &&' "$patch" >/dev/null
grep -F 'is_selinux_enabled() <= 0;' "$patch" >/dev/null
grep -F 'if (isRoydContainerWithoutSelinux()) {' "$patch" >/dev/null
grep -F 'ROYD: continuing without legacy iptables bandwidth rules because' "$patch" >/dev/null
grep -F 'exit(1);' "$patch" >/dev/null

# The stock initialisation attempt, failure diagnostic and fatal branch remain present.
grep -F 'if (int ret = bandwidthCtrl.enableBandwidthControl()) {' "$patch" >/dev/null
grep -F 'gLog.error("Failed to initialize BandwidthController (%s)", strerror(-ret));' "$patch" >/dev/null
grep -F '+        } else {' "$patch" >/dev/null

if grep -Fq 'ROYD_DIAG' "$patch"; then
  echo 'permanent netd iptables patch retains a diagnostic-only marker' >&2
  exit 1
fi

printf '%s\n' 'Android 15 netd iptables container contract passed'
