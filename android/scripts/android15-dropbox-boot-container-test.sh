#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
patch="$root/android/patches/android-15.0.0_r36/0022-activity-manager-avoid-early-dropbox-recursion.patch"

[ -f "$patch" ] || { echo 'missing Android 15 early DropBox recursion patch' >&2; exit 1; }
[ "$(grep -c '^diff --git a/frameworks/base/services/core/java/com/android/server/am/ActivityManagerService.java' "$patch")" -eq 1 ]
[ "$(grep -c '^diff --git ' "$patch")" -eq 1 ]
grep -F '+import android.os.SELinux;' "$patch" >/dev/null
grep -F '"1".equals(System.getenv("ROYD_CONTAINER")) && !SELinux.isSELinuxEnabled()' "$patch" >/dev/null
grep -F 'ServiceManager.checkService(Context.DROPBOX_SERVICE) == null) {' "$patch" >/dev/null
grep -F 'SystemServiceRegistry for the absent service' "$patch" >/dev/null

# The narrow pre-publication branch must precede the unchanged stock lookup and return only when
# the explicit container gate is active and the Binder service is absent.
gate_line=$(grep -n '"1".equals(System.getenv("ROYD_CONTAINER"))' "$patch" | cut -d: -f1)
lookup_line=$(grep -n 'dbox = mContext.getSystemService(DropBoxManager.class);' "$patch" | cut -d: -f1)
[ "$gate_line" -lt "$lookup_line" ] || {
  echo 'early DropBox guard does not precede the stock manager lookup' >&2
  exit 1
}
if grep -Eq '^[+-].*(dbox = mContext\.getSystemService|dbox == null|dbox\.isTagEnabled)' "$patch"; then
  echo 'early DropBox patch changes stock service lookup or tag handling' >&2
  exit 1
fi

printf '%s\n' 'Android 15 early DropBox boot contract passed'
