#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
patch="$root/android/patches/android-15.0.0_r36/0011-logd-tolerate-missing-background-cgroup.patch"

[ -f "$patch" ] || { echo 'missing Android 15 royd logd scheduling patch' >&2; exit 1; }
[ "$(grep -c '^diff --git a/system/logging/logd/' "$patch")" -eq 2 ]
[ "$(grep -c '^diff --git ' "$patch")" -eq 2 ]
grep -F '+        "libselinux",' "$patch" >/dev/null
grep -F '#include <selinux/selinux.h>' "$patch" >/dev/null
grep -F 'static bool IsRoydContainerWithoutSelinux() {' "$patch" >/dev/null
grep -F 'strcmp(royd_container, "1") == 0 &&' "$patch" >/dev/null
grep -F 'is_selinux_enabled() <= 0;' "$patch" >/dev/null
grep -F 'if (set_sched_policy(0, SP_BACKGROUND) < 0) {' "$patch" >/dev/null
grep -F 'const int saved_errno = errno;' "$patch" >/dev/null
grep -F 'if (saved_errno == ENOENT && IsRoydContainerWithoutSelinux()) {' "$patch" >/dev/null
grep -F 'ROYD: background scheduling profile unavailable because' "$patch" >/dev/null
grep -F 'errno = saved_errno;' "$patch" >/dev/null
grep -F 'PLOG(FATAL) << "failed to set background scheduling policy";' "$patch" >/dev/null

if grep -Fq 'ROYD_DIAG' "$patch"; then
  echo 'permanent logd scheduling patch retains a diagnostic-only marker' >&2
  exit 1
fi

printf '%s\n' 'Android 15 logd scheduling container contract passed'
