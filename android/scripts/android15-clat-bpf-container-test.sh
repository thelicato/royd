#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
patch="$root/android/patches/android-15.0.0_r36/0014-connectivity-skip-clat-selinux-context-without-selinux.patch"

[ -f "$patch" ] || { echo 'missing Android 15 royd CLAT BPF verification patch' >&2; exit 1; }
[ "$(grep -c '^diff --git a/packages/modules/Connectivity/service/jni/com_android_server_connectivity_ClatCoordinator.cpp' "$patch")" -eq 1 ]
[ "$(grep -c '^diff --git ' "$patch")" -eq 1 ]
grep -F 'static bool isRoydContainerWithoutSelinux() {' "$patch" >/dev/null
grep -F 'strcmp(roydContainer, "1") == 0 &&' "$patch" >/dev/null
grep -F 'access("/sys/fs/selinux/enforce", F_OK) != 0;' "$patch" >/dev/null
grep -F 'if (!isRoydContainerWithoutSelinux()) {' "$patch" >/dev/null
grep -F 'ROYD: skipping CLAT SELinux context verification because' "$patch" >/dev/null

# All non-context permission and BPF object checks must remain unconditional.
if grep -Eq '^[+-].*(lstat\(|s\.st_mode|s\.st_uid|s\.st_gid|retrieveProgram|mapRetrieveRO|mapRetrieveLocklessRW|bpf_obj_get)' "$patch"; then
  echo 'CLAT patch changes a non-context permission or BPF object check' >&2
  exit 1
fi
if grep -Eq '^[+-].*if \(fatal\) abort\(\);' "$patch"; then
  echo 'CLAT patch changes the stock fatal verification result' >&2
  exit 1
fi

if grep -Fq 'ROYD_DIAG' "$patch"; then
  echo 'permanent CLAT BPF patch retains a diagnostic-only marker' >&2
  exit 1
fi

printf '%s\n' 'Android 15 CLAT BPF container contract passed'
