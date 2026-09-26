#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
patch="$root/android/patches/android-15.0.0_r36/0004-vold-support-royd-container-selinux-disabled.patch"

[ -f "$patch" ] || { echo 'missing Android 15 royd vold patch' >&2; exit 1; }
[ "$(grep -c '^diff --git a/system/vold/' "$patch")" -eq 2 ]
[ "$(grep -c 'ROYD_CONTAINER' "$patch")" -eq 2 ]
[ "$(grep -c 'is_selinux_enabled() <= 0' "$patch")" -eq 2 ]
[ "$(grep -c 'saved_errno == EINVAL' "$patch")" -eq 2 ]
[ "$(grep -c 'ROYD: setfscreatecon unavailable with kernel SELinux' "$patch")" -eq 2 ]
grep -F 'if (secontext && !is_royd_selinux_disabled()) {' "$patch" >/dev/null

# Normal Android and non-EINVAL failures must retain their stock fatal handling.
[ "$(grep -c 'LOG(ERROR) << "Failed to setfscreatecon for directory " << path;' "$patch")" -eq 4 ]
grep -F 'return -EINVAL;' "$patch" >/dev/null
grep -F 'return false;' "$patch" >/dev/null

printf '%s\n' 'Android 15 vold container contract passed'
