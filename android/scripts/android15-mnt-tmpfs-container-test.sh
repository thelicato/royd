#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
patch="$root/android/patches/android-15.0.0_r36/0029-init-restore-container-mnt-tmpfs.patch"

[ -f "$patch" ] || { echo 'missing Android 15 container /mnt tmpfs patch' >&2; exit 1; }
[ "$(grep -c '^diff --git a/system/core/init/init.cpp' "$patch")" -eq 1 ]
[ "$(grep -c '^diff --git ' "$patch")" -eq 1 ]
grep -F '+#include <selinux/selinux.h>' "$patch" >/dev/null
grep -F 'const char* royd_container = getenv("ROYD_CONTAINER");' "$patch" >/dev/null
grep -F 'strcmp(royd_container, "1") != 0' "$patch" >/dev/null
grep -F 'is_selinux_enabled() > 0' "$patch" >/dev/null
grep -F 'getenv(kEnvFirstStageStartedAt) != nullptr' "$patch" >/dev/null
grep -F 'mount("tmpfs", "/mnt", "tmpfs", MS_NOEXEC | MS_NOSUID | MS_NODEV,' "$patch" >/dev/null
grep -F '"mode=0755,uid=0,gid=1000") != 0' "$patch" >/dev/null
grep -F 'PLOG(FATAL) << "Failed to mount Android runtime staging tmpfs at /mnt";' "$patch" >/dev/null
grep -F 'ROYD: mounted Android runtime staging tmpfs at /mnt' "$patch" >/dev/null

# The replacement for the skipped first stage must run near the start of second stage and retain
# every stock second-stage mount and namespace operation.
call_line=$(grep -n '^+    MountRoydContainerMnt();' "$patch" | cut -d: -f1)
sigpipe_line=$(grep -n ' // Init should not crash because of a dependence on any other process' "$patch" | cut -d: -f1)
[ -n "$call_line" ] && [ -n "$sigpipe_line" ] && [ "$call_line" -lt "$sigpipe_line" ] || {
  echo 'container /mnt mount is not at the start of second-stage init' >&2
  exit 1
}
if grep -Eq '^-.*(PropertyInit|MountExtraFilesystems|SetupMountNamespaces)' "$patch"; then
  echo 'container /mnt patch changes stock second-stage setup' >&2
  exit 1
fi

printf '%s\n' 'Android 15 container /mnt tmpfs contract passed'
