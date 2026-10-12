#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
patch="$root/android/patches/android-15.0.0_r36/0034-framework-use-unprivileged-container-psi-window.patch"

[ -f "$patch" ] || { echo 'missing Android 15 ActivityManager PSI patch' >&2; exit 1; }
[ "$(grep -c '^diff --git a/frameworks/base/services/core/jni/com_android_server_am_LowMemDetector.cpp' "$patch")" -eq 1 ]
[ "$(grep -c '^diff --git ' "$patch")" -eq 1 ]
grep -F 'static bool IsRoydContainerWithoutSelinux() {' "$patch" >/dev/null
grep -F 'strcmp(roydContainer, "1") == 0' "$patch" >/dev/null
grep -F 'access("/sys/fs/selinux/enforce", F_OK) != 0;' "$patch" >/dev/null
grep -F 'const int windowScale = IsRoydContainerWithoutSelinux() ? 2 : 1;' "$patch" >/dev/null
grep -F 'ROYD: using unprivileged 2-second PSI windows for ActivityManager' "$patch" >/dev/null
grep -F 'PSI_LOW_STALL_US * windowScale' "$patch" >/dev/null
grep -F 'PSI_MEDIUM_STALL_US * windowScale' "$patch" >/dev/null
grep -F 'PSI_HIGH_STALL_US * windowScale' "$patch" >/dev/null
[ "$(grep -c 'PSI_WINDOW_SIZE_US \* windowScale' "$patch")" -eq 3 ]

# Only the explicit container gate scales the stock thresholds and window together. Keep the
# detector's pressure levels, epoll registration, wait loop and failure handling unchanged.
grep -F 'register_psi_monitor(epollfd, low_psi_fd, (void*)PRESSURE_LOW)' "$patch" >/dev/null
grep -F 'register_psi_monitor(epollfd, medium_psi_fd,' "$patch" >/dev/null
grep -F 'register_psi_monitor(epollfd, high_psi_fd, (void*)PRESSURE_HIGH)' "$patch" >/dev/null
if grep -Eq '^-.*(register_psi_monitor|epoll_wait|Failed to register psi trigger)' "$patch"; then
  echo 'ActivityManager PSI patch changes the stock registration or wait path' >&2
  exit 1
fi

printf '%s\n' 'Android 15 ActivityManager unprivileged PSI contract passed'
