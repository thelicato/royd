#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
patch="$root/android/patches/android-15.0.0_r36/0027-framework-skip-packages-list-selinux-context.patch"

[ -f "$patch" ] || { echo 'missing Android 15 packages.list SELinux-context patch' >&2; exit 1; }
[ "$(grep -c '^diff --git a/frameworks/base/services/core/java/com/android/server/pm/Settings.java' "$patch")" -eq 1 ]
[ "$(grep -c '^diff --git ' "$patch")" -eq 1 ]
grep -F '"1".equals(System.getenv("ROYD_CONTAINER")) && !SELinux.isSELinuxEnabled()' "$patch" >/dev/null
grep -F '+            writePackageListLPrInternal(creatingUserId);' "$patch" >/dev/null
grep -F '+            return;' "$patch" >/dev/null
grep -F 'String ctx = SELinux.fileSelabelLookup(filename);' "$patch" >/dev/null
grep -F 'if (!SELinux.setFSCreateContext(ctx)) {' "$patch" >/dev/null
grep -F 'SELinux.setFSCreateContext(null);' "$patch" >/dev/null

# Only the explicit container-without-SELinux branch may bypass context setup. The package-list
# writer and every stock SELinux operation must remain present for all other Android environments.
if grep -Eq '^-.*(writePackageListLPrInternal|fileSelabelLookup|setFSCreateContext)' "$patch"; then
  echo 'packages.list patch changes the stock writer or SELinux path' >&2
  exit 1
fi

printf '%s\n' 'Android 15 packages.list SELinux-context container contract passed'
