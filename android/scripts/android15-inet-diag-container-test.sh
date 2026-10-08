#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
patch="$root/android/patches/android-15.0.0_r36/0024-connectivity-cache-missing-inet-diag.patch"

[ -f "$patch" ] || { echo 'missing Android 15 inet-diag compatibility patch' >&2; exit 1; }
[ "$(grep -c '^diff --git a/packages/modules/Connectivity/staticlibs/device/com/android/net/module/util/netlink/' "$patch")" -eq 2 ]
[ "$(grep -c '^diff --git ' "$patch")" -eq 2 ]
grep -F 'static boolean isRoydContainerWithoutSelinux() {' "$patch" >/dev/null
grep -F '"1".equals(System.getenv("ROYD_CONTAINER"))' "$patch" >/dev/null
grep -F '!new File("/sys/fs/selinux/enforce").exists();' "$patch" >/dev/null
grep -F 'nlFamily != NETLINK_INET_DIAG' "$patch" >/dev/null
grep -F 'error.error == -ENOENT' "$patch" >/dev/null
grep -F 'error.msg.nlmsg_type == SOCK_DIAG_BY_FAMILY' "$patch" >/dev/null
grep -F '(error.msg.nlmsg_flags & dumpFlags) == dumpFlags' "$patch" >/dev/null
grep -F 'throw new ErrnoException(' "$patch" >/dev/null
grep -F 'private static volatile boolean sRoydInetDiagUnavailable = false;' "$patch" >/dev/null
grep -F 'sRoydInetDiagUnavailable = true;' "$patch" >/dev/null
grep -F 'skipping subsequent socket-destruction dumps' "$patch" >/dev/null

# Unsupported kernels fail fast once, while all other failures retain the stock exception path.
grep -F 'if (e.errno != ENOENT || !NetlinkUtils.isRoydContainerWithoutSelinux()) {' "$patch" >/dev/null
grep -F '+                throw e;' "$patch" >/dev/null
grep -F 'Log.wtf(TAG, "Received unexpected netlink message: " + nlMsg);' "$patch" >/dev/null
! grep -Eq '^[+-].*sendNetlinkDestroyRequest' "$patch" || {
  echo 'inet-diag patch changes the stock socket-destruction request' >&2
  exit 1
}

printf '%s\n' 'Android 15 missing inet-diag container contract passed'
