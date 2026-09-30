#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
patch="$root/android/patches/android-15.0.0_r36/0005-system-suspend-isolate-royd-container.patch"

[ -f "$patch" ] || { echo 'missing Android 15 royd SystemSuspend patch' >&2; exit 1; }
[ "$(grep -c '^diff --git a/system/hardware/interfaces/suspend/1.0/default/' "$patch")" -eq 2 ]
[ "$(grep -c 'ROYD_CONTAINER' "$patch")" -eq 2 ]
[ "$(grep -c 'is_selinux_enabled() <= 0' "$patch")" -eq 1 ]
grep -F '"libselinux",' "$patch" >/dev/null
grep -F 'const bool disableHostSuspend = isRoydContainerWithoutSelinux();' "$patch" >/dev/null
grep -F 'ROYD: isolating Android SystemSuspend from host power state because ' "$patch" >/dev/null
grep -F 'if (disableHostSuspend || wakeupCountFd < 0 || stateFd < 0) {' "$patch" >/dev/null
grep -F 'Socketpair(SOCK_STREAM, &wakeupCountFd, &stateFd);' "$patch" >/dev/null

# The permanent gate must not retain the diagnostic-only marker descriptor.
if grep -Fq 'memfd' "$patch"; then
  echo 'permanent SystemSuspend patch contains a diagnostic memfd' >&2
  exit 1
fi

# Normal Android retains both stock host power opens and their error handling.
[ "$(grep -c 'open(kSysPowerWakeupCount, O_CLOEXEC | O_RDWR)' "$patch")" -eq 2 ]
[ "$(grep -c 'open(kSysPowerState, O_CLOEXEC | O_RDWR)' "$patch")" -eq 2 ]
[ "$(grep -c 'PLOG(ERROR) << "error opening " << kSysPower' "$patch")" -eq 4 ]

printf '%s\n' 'Android 15 SystemSuspend container contract passed'
