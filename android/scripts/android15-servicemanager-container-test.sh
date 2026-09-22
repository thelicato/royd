#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
patch="$root/android/patches/android-15.0.0_r36/0002-servicemanager-support-royd-container-selinux-disabled.patch"

[ -f "$patch" ] || { echo 'missing Android 15 royd servicemanager patch' >&2; exit 1; }
grep -F 'IsRoydContainerWithoutSelinux' "$patch" >/dev/null
grep -F 'ROYD_CONTAINER' "$patch" >/dev/null
grep -F 'is_selinux_enabled() <= 0' "$patch" >/dev/null
grep -F 'mSkipSelinux = IsRoydContainerWithoutSelinux();' "$patch" >/dev/null
grep -F 'if (mSkipSelinux) {' "$patch" >/dev/null
grep -F 'servicemanager access checks are disabled' "$patch" >/dev/null
grep -F 'return true;' "$patch" >/dev/null
# The patch must gate, not replace, the existing Android implementation.
if grep -Fq -- '-    CHECK(selinux_status_open(true /*fallback*/) >= 0);' "$patch"; then
  echo 'error: task 052 patch removes normal SELinux status initialisation' >&2
  exit 1
fi

printf '%s\n' 'Android 15 servicemanager container contract passed'
