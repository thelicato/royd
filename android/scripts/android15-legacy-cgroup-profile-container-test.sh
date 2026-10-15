#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
patch="$root/android/patches/android-15.0.0_r36/0039-libprocessgroup-skip-unavailable-legacy-profiles.patch"
mount_patch="$root/android/patches/android-15.0.0_r36/0040-libprocessgroup-detect-unmounted-legacy-profiles.patch"

[ -f "$patch" ] || { echo 'missing Android 15 legacy cgroup-profile patch' >&2; exit 1; }
[ -f "$mount_patch" ] || {
  echo 'missing Android 15 legacy cgroup-profile mount detection patch' >&2
  exit 1
}
[ "$(grep -c '^diff --git a/system/core/libprocessgroup/task_profiles.cpp' "$patch")" -eq 1 ]
[ "$(grep -c '^diff --git ' "$patch")" -eq 1 ]
grep -F 'bool ShouldSkipRoydLegacyCgroup(const CgroupControllerWrapper& controller)' \
  "$patch" >/dev/null
grep -F 'strcmp(royd_container, "1") != 0' "$patch" >/dev/null
grep -F 'access("/sys/fs/selinux/enforce", F_OK) == 0' "$patch" >/dev/null
grep -F 'controller.version() != 1' "$patch" >/dev/null
grep -F 'access(controller.path(), F_OK) != 0 && errno == ENOENT' "$patch" >/dev/null
grep -F 'if (ShouldSkipRoydLegacyCgroup(controller)) {' "$patch" >/dev/null
grep -F 'ROYD: skipping task-profile actions for unavailable' "$patch" >/dev/null
[ "$(grep -c '^diff --git a/system/core/libprocessgroup/task_profiles.cpp' "$mount_patch")" -eq 1 ]
[ "$(grep -c '^diff --git ' "$mount_patch")" -eq 1 ]
grep -F -- '-    return access(controller.path(), F_OK) != 0 && errno == ENOENT;' \
  "$mount_patch" >/dev/null
grep -F 'const std::string procs_path = std::string(controller.path()) + "/cgroup.procs";' \
  "$mount_patch" >/dev/null
grep -F 'access(procs_path.c_str(), F_OK) != 0 && errno == ENOENT' "$mount_patch" >/dev/null

# The gated omission must precede the unchanged stock distinction between v1 JoinCgroup actions
# and v2 controllers. Other action types and profile execution remain untouched.
grep -F 'profile->Add(std::make_unique<SetCgroupAction>(controller, path));' "$patch" >/dev/null
grep -F 'if (controller.version() == 1) {' "$patch" >/dev/null
if grep -Eq '^[-+].*(SetTimerSlack|SetSchedulerPolicy|SetAttribute|WriteFile)' "$patch"; then
  echo 'Android 15 legacy cgroup-profile patch changes non-cgroup profile actions' >&2
  exit 1
fi
if grep -Eq '^-.*(SetCgroupAction|controller\.version\(\) == 1)' "$patch"; then
  echo 'Android 15 legacy cgroup-profile patch removes stock cgroup handling' >&2
  exit 1
fi
if grep -Eq '^[+-].*(SetTimerSlack|SetSchedulerPolicy|SetAttribute|WriteFile|SetCgroupAction)' \
    "$mount_patch"; then
  echo 'Android 15 legacy cgroup-profile mount detection changes profile actions' >&2
  exit 1
fi

printf '%s\n' 'Android 15 legacy cgroup-profile contract passed'
