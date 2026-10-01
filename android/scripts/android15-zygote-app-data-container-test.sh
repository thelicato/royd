#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
patch="$root/android/patches/android-15.0.0_r36/0007-zygote-support-app-data-isolation-without-selinux.patch"

[ -f "$patch" ] || { echo 'missing Android 15 royd Zygote app-data patch' >&2; exit 1; }
[ "$(grep -c '^diff --git a/frameworks/base/core/jni/com_android_internal_os_Zygote.cpp' "$patch")" -eq 1 ]
[ "$(grep -c '^diff --git ' "$patch")" -eq 1 ]
grep -F '#include <selinux/selinux.h>' "$patch" >/dev/null
grep -F 'static bool IsRoydContainerWithoutSelinux() {' "$patch" >/dev/null
grep -F 'strcmp(royd_container, "1") == 0 &&' "$patch" >/dev/null
grep -F 'is_selinux_enabled() <= 0;' "$patch" >/dev/null
grep -F 'const bool skip_selinux_labelling = IsRoydContainerWithoutSelinux();' "$patch" >/dev/null
grep -F 'ROYD: skipping app-data SELinux context copy and relabelling' "$patch" >/dev/null
grep -F 'if (!skip_selinux_labelling) {' "$patch" >/dev/null

# The mount namespace, tmpfs and per-package bind-mount isolation must remain unconditional.
if grep -Eq '^[+-].*(MountAppDataTmpFs|isolateAppDataPerPackage)' "$patch"; then
  echo 'Zygote patch changes app-data mount isolation rather than only SELinux labelling' >&2
  exit 1
fi

# Stock context reads, relabelling and cleanup remain present outside the exact gate.
grep -F '+    if (getfilecon(internalCePath, &dataUserdirContext) < 0) {' "$patch" >/dev/null
grep -F '+    if (getfilecon("/data/misc", &dataFileContext) < 0) {' "$patch" >/dev/null
grep -F '+    relabelSubdirs(internalCePath, dataFileContext, fail_fn);' "$patch" >/dev/null
grep -F '+    relabelDir(internalCePath, dataUserdirContext, fail_fn);' "$patch" >/dev/null
grep -F '+    freecon(dataUserdirContext);' "$patch" >/dev/null
grep -F '+    freecon(dataFileContext);' "$patch" >/dev/null

if grep -Fq 'ROYD_DIAG' "$patch"; then
  echo 'permanent Zygote app-data patch retains a diagnostic-only marker' >&2
  exit 1
fi

printf '%s\n' 'Android 15 Zygote app-data container contract passed'
