#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
patch="$root/android/patches/android-15.0.0_r36/0026-connectivity-skip-absent-container-ethernet-probe.patch"

[ -f "$patch" ] || { echo 'missing Android 15 optional Ethernet probe patch' >&2; exit 1; }
[ "$(grep -c '^diff --git a/packages/modules/Connectivity/Tethering/src/com/android/networkstack/tethering/Tethering.java' "$patch")" -eq 1 ]
[ "$(grep -c '^diff --git ' "$patch")" -eq 1 ]
grep -F '+import java.io.File;' "$patch" >/dev/null
grep -F 'private static boolean isRoydContainerWithoutSelinux() {' "$patch" >/dev/null
grep -F '"1".equals(System.getenv("ROYD_CONTAINER"))' "$patch" >/dev/null
grep -F '!new File("/sys/fs/selinux/enforce").exists();' "$patch" >/dev/null
grep -F '!hasSystemFeature(PackageManager.FEATURE_ETHERNET)' "$patch" >/dev/null
grep -F '!hasSystemFeature(PackageManager.FEATURE_USB_HOST)) {' "$patch" >/dev/null
grep -F '+            return false;' "$patch" >/dev/null

# Products that advertise either feature, and every non-container environment, retain the stock
# EthernetManager lookup. The patch must not add a hardware feature or manipulate an interface.
grep -F 'return mContext.getSystemService(Context.ETHERNET_SERVICE) != null;' "$patch" >/dev/null
! grep -Eq '^[+].*(android\.hardware\.ethernet|interfaceSetCfg|interfaceAddAddress)' "$patch" || {
  echo 'optional Ethernet probe patch advertises hardware or changes an interface' >&2
  exit 1
}

printf '%s\n' 'Android 15 optional Ethernet probe container contract passed'
