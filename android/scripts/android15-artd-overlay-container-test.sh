#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
patch="$root/android/patches/android-15.0.0_r36/0037-artd-classify-container-root-overlay.patch"

[ -f "$patch" ] || { echo 'missing Android 15 ART overlay patch' >&2; exit 1; }
[ "$(grep -c '^diff --git a/art/artd/artd.cc' "$patch")" -eq 1 ]
[ "$(grep -c '^diff --git ' "$patch")" -eq 1 ]
grep -F 'bool IsRoydContainerWithoutSelinux() {' "$patch" >/dev/null
grep -F 'strcmp(royd_container, "1") == 0' "$patch" >/dev/null
grep -F 'is_selinux_enabled() <= 0;' "$patch" >/dev/null
grep -F 'it->mount_point == "/" && IsRoydContainerWithoutSelinux()' "$patch" >/dev/null
grep -F 'ROYD: treating the OCI root overlay as a system partition for ART' "$patch" >/dev/null
grep -F '*_aidl_return = true;' "$patch" >/dev/null
grep -F 'return ScopedAStatus::ok();' "$patch" >/dev/null

# Keep the exception limited to the explicitly gated OCI root. Stock Android must continue to
# ignore remount overlays, classify writable mounts and retain its conservative error fallback.
grep -F '// Ignore the overlays created by `remount`.' "$patch" >/dev/null
grep -F 'continue;' "$patch" >/dev/null
if grep -Eq '^-.*(MS_RDONLY|incremental-fs|Fstab entries not found)' "$patch"; then
  echo 'Android 15 ART overlay patch changes stock mount classification or fallback handling' >&2
  exit 1
fi

printf '%s\n' 'Android 15 ART root-overlay contract passed'
