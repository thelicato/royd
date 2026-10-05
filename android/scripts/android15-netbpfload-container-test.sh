#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
patch="$root/android/patches/android-15.0.0_r36/0012-netbpfload-preserve-host-bpf-sysctls.patch"

[ -f "$patch" ] || { echo 'missing Android 15 royd NetBpfLoad patch' >&2; exit 1; }
[ "$(grep -c '^diff --git a/packages/modules/Connectivity/bpf/loader/NetBpfLoad.cpp' "$patch")" -eq 1 ]
[ "$(grep -c '^diff --git ' "$patch")" -eq 1 ]
grep -F 'static bool isRoydContainerWithoutSelinux() {' "$patch" >/dev/null
grep -F 'strcmp(roydContainer, "1") == 0 &&' "$patch" >/dev/null
grep -F '!exists("/sys/fs/selinux/enforce");' "$patch" >/dev/null
grep -F 'const bool preserveHostBpfSysctls = isRoydContainerWithoutSelinux();' "$patch" >/dev/null
grep -F 'ROYD: preserving host BPF sysctls because ROYD_CONTAINER=1 and kernel' "$patch" >/dev/null
grep -F 'if (runningAsRoot && !preserveHostBpfSysctls) {' "$patch" >/dev/null
grep -F 'if (isAtLeastU && !preserveHostBpfSysctls) {' "$patch" >/dev/null

# Stock sysctl operations, private bpffs setup and BPF program loading remain unchanged.
if grep -Eq '^[+-].*(writeProcSysFile|createSysFsBpfSubDir|loadAllElfObjects)' "$patch"; then
  echo 'NetBpfLoad patch changes a stock BPF operation instead of only gating sysctl blocks' >&2
  exit 1
fi

if grep -Fq 'ROYD_DIAG' "$patch"; then
  echo 'permanent NetBpfLoad patch retains a diagnostic-only marker' >&2
  exit 1
fi

printf '%s\n' 'Android 15 NetBpfLoad container contract passed'
