#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
patch="$root/android/patches/android-15.0.0_r36/0023-netd-skip-unused-tether-stats.patch"

[ -f "$patch" ] || { echo 'missing Android 15 unused tether-stats patch' >&2; exit 1; }
[ "$(grep -c '^diff --git a/system/netd/server/TetherController.cpp' "$patch")" -eq 1 ]
[ "$(grep -c '^diff --git ' "$patch")" -eq 1 ]
grep -F '+#include <unistd.h>' "$patch" >/dev/null
grep -F 'bool isRoydContainerWithoutSelinux() {' "$patch" >/dev/null
grep -F 'strcmp(roydContainer, "1") == 0 &&' "$patch" >/dev/null
grep -F 'access("/sys/fs/selinux/enforce", F_OK) != 0;' "$patch" >/dev/null
grep -F 'if (mFwdIfaces.empty() && isRoydContainerWithoutSelinux()) {' "$patch" >/dev/null
grep -F '+        return statsList;' "$patch" >/dev/null

# A configured forwarding pair must retain the stock IPv4 and IPv6 counter queries and failures.
grep -F 'for (const IptablesTarget target : {V4, V6}) {' "$patch" >/dev/null
grep -F 'iptablesRestoreFunction(target, GET_TETHER_STATS_COMMAND, &statsString)' "$patch" >/dev/null
grep -F 'failed to fetch tether stats' "$patch" >/dev/null
if grep -Eq '^[+-].*mFwdIfaces\.(clear|erase)' "$patch"; then
  echo 'unused tether-stats patch changes forwarding-pair state' >&2
  exit 1
fi

printf '%s\n' 'Android 15 unused tether-stats container contract passed'
