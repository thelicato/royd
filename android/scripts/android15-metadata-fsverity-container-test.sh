#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
patch="$root/android/patches/android-15.0.0_r36/0038-framework-skip-container-metadata-fsverity.patch"

[ -f "$patch" ] || { echo 'missing Android 15 metadata fs-verity patch' >&2; exit 1; }
[ "$(grep -c '^diff --git a/frameworks/base/services/core/java/com/android/server/security/FileIntegrity.java' "$patch")" -eq 1 ]
[ "$(grep -c '^diff --git ' "$patch")" -eq 1 ]
grep -F 'import android.os.SELinux;' "$patch" >/dev/null
grep -F '"1".equals(System.getenv("ROYD_CONTAINER")) && !SELinux.isSELinuxEnabled()' \
  "$patch" >/dev/null
[ "$(grep -c 'if (shouldSkipForRoydContainer()) {' "$patch")" -eq 2 ]
grep -F 'ROYD: skipping unavailable fs-verity for system-server metadata' "$patch" >/dev/null
grep -F 'VerityUtils.setUpFsverity(parcelFileDescriptor.getFd());' "$patch" >/dev/null

# Keep the exception at the system-server metadata helper. APK, font, installer and app-facing
# verity enforcement must retain their existing direct VerityUtils and service paths.
if grep -Eq '^diff --git a/.*(VerityUtils|FileIntegrityService|PackageInstaller|Font)' "$patch"; then
  echo 'Android 15 metadata fs-verity patch changes a direct integrity-enforcement path' >&2
  exit 1
fi
if grep -Eq '^-[^/-].*(VerityUtils\.setUpFsverity|ParcelFileDescriptor\.open)' "$patch"; then
  echo 'Android 15 metadata fs-verity patch removes stock setup operations' >&2
  exit 1
fi

printf '%s\n' 'Android 15 metadata fs-verity contract passed'
