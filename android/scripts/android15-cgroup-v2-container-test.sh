#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
patch="$root/android/patches/android-15.0.0_r36/0017-libprocessgroup-use-container-cgroup-subtree.patch"
fix_patch="$root/android/patches/android-15.0.0_r36/0018-libprocessgroup-fix-cgroup-name-comparison.patch"
netd_patch="$root/android/patches/android-15.0.0_r36/0019-connectivity-allow-delegated-cgroup-bpf-root.patch"
cgroups="$root/android/royd/vendor/royd/cgroups.json"

[ -f "$patch" ] || { echo 'missing Android 15 libprocessgroup cgroup-v2 patch' >&2; exit 1; }
[ -f "$fix_patch" ] || { echo 'missing Android 15 libprocessgroup comparison fix' >&2; exit 1; }
[ -f "$netd_patch" ] || { echo 'missing Android 15 delegated cgroup netd patch' >&2; exit 1; }
[ -f "$cgroups" ] || { echo 'missing royd cgroup-v2 descriptor' >&2; exit 1; }
[ "$(grep -c '^diff --git a/system/core/libprocessgroup/setup/cgroup_map_write.cpp' "$patch")" -eq 1 ]
[ "$(grep -c '^diff --git ' "$patch")" -eq 1 ]
grep -F 'static bool IsRoydContainerCgroup(const CgroupController* controller) {' "$patch" >/dev/null
grep -F 'strcmp(royd_container, "1") == 0 &&' "$patch" >/dev/null
grep -F 'access("/sys/fs/selinux/enforce", F_OK) != 0 &&' "$patch" >/dev/null
grep -F 'strcmp(controller->path(), "/sys/fs/cgroup/royd") == 0 &&' "$patch" >/dev/null
grep -F 'access("/sys/fs/cgroup/cgroup.controllers", F_OK) == 0;' "$patch" >/dev/null
grep -F 'if (IsRoydContainerCgroup(controller)) {' "$patch" >/dev/null
grep -F 'ChangePathModeAndOwner(controller->path(), descriptor.mode(), descriptor.uid(),' "$patch" >/dev/null
grep -F 'android::base::WriteStringToFile(std::to_string(getpid()), procs_path)' "$patch" >/dev/null
grep -F 'Failed to move Android init into' "$patch" >/dev/null
grep -F 'ROYD: using delegated cgroup v2 subtree at' "$patch" >/dev/null
[ "$(grep -c '^diff --git a/system/core/libprocessgroup/setup/cgroup_map_write.cpp' "$fix_patch")" -eq 1 ]
[ "$(grep -c '^diff --git ' "$fix_patch")" -eq 1 ]
grep -F -- '-            strcmp(controller->name(), CGROUPV2_HIERARCHY_NAME) == 0 &&' "$fix_patch" >/dev/null
grep -F -- '+            controller->name() == CGROUPV2_HIERARCHY_NAME &&' "$fix_patch" >/dev/null
[ "$(grep -c '^diff --git a/packages/modules/Connectivity/bpf/netd/BpfHandler.cpp' "$netd_patch")" -eq 1 ]
[ "$(grep -c '^diff --git ' "$netd_patch")" -eq 1 ]
grep -F 'static bool isRoydDelegatedCgroup(const char* cg2_path) {' "$netd_patch" >/dev/null
grep -F '!strcmp(cg2_path, "/sys/fs/cgroup/royd")' "$netd_patch" >/dev/null
grep -F 'roydContainer != nullptr && !strcmp(roydContainer, "1") &&' "$netd_patch" >/dev/null
grep -F 'access("/sys/fs/selinux/enforce", F_OK) != 0;' "$netd_patch" >/dev/null
grep -F '!isRoydDelegatedCgroup(cg2_path)) {' "$netd_patch" >/dev/null
grep -F 'ROYD: attaching network BPF to %s' "$netd_patch" >/dev/null

# The gated branch returns before the unchanged stock mount in the source.
grep -F '+        return true;' "$patch" >/dev/null
if grep -Eq '^[+-].*mount\("none", controller->path\(\), "cgroup2"' "$patch"; then
  echo 'libprocessgroup patch changes the stock cgroup2 mount' >&2
  exit 1
fi

grep -Fq '"Path": "/sys/fs/cgroup/royd"' "$cgroups"
grep -Fq '"Mode": "0775"' "$cgroups"
grep -Fq '"UID": "system"' "$cgroups"
grep -Fq '"GID": "system"' "$cgroups"
! grep -Fq '"Cgroups"' "$cgroups" || {
  echo 'royd cgroup descriptor unexpectedly overrides legacy cgroups' >&2
  exit 1
}

printf '%s\n' 'Android 15 delegated cgroup-v2 contract passed'
