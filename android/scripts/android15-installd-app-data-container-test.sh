#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
patch="$root/android/patches/android-15.0.0_r36/0010-installd-support-app-data-without-selinux.patch"

[ -f "$patch" ] || { echo 'missing Android 15 royd Installd app-data patch' >&2; exit 1; }
[ "$(grep -c '^diff --git a/frameworks/native/cmds/installd/InstalldNativeService.cpp' "$patch")" -eq 1 ]
[ "$(grep -c '^diff --git ' "$patch")" -eq 1 ]
grep -F '#include <selinux/selinux.h>' "$patch" >/dev/null
grep -F 'static bool isRoydContainerWithoutSelinux() {' "$patch" >/dev/null
grep -F 'strcmp(roydContainer, "1") == 0 &&' "$patch" >/dev/null
grep -F 'is_selinux_enabled() <= 0;' "$patch" >/dev/null
grep -F 'if (!inProgress && isRoydContainerWithoutSelinux()) {' "$patch" >/dev/null
grep -F 'ROYD: skipping Installd app-data SELinux context comparison for' "$patch" >/dev/null
grep -F 'because ROYD_CONTAINER=1 and kernel SELinux is disabled' "$patch" >/dev/null

# New-directory restorecon, interrupted-operation handling, and stock comparison remain unchanged.
if grep -Eq '^[+-].*if \(!existing\)' "$patch"; then
  echo 'Installd patch changes the new-directory branch' >&2
  exit 1
fi
if grep -Eq '^[+-].*selinux_android_restorecon_pkgdir' "$patch"; then
  echo 'Installd patch changes a stock restorecon call' >&2
  exit 1
fi
grep -F 'bool inProgress = getRestoreconInProgress(path);' "$patch" >/dev/null
grep -F 'if (before = lgetfilecon(path); before.empty()) {' "$patch" >/dev/null

if grep -Fq 'ROYD_DIAG' "$patch"; then
  echo 'permanent Installd app-data patch retains a diagnostic-only marker' >&2
  exit 1
fi

printf '%s\n' 'Android 15 Installd app-data container contract passed'
