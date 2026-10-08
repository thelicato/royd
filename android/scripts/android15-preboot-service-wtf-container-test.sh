#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
patch="$root/android/patches/android-15.0.0_r36/0025-framework-suppress-container-preboot-service-wtfs.patch"

[ -f "$patch" ] || { echo 'missing Android 15 pre-boot service WTF patch' >&2; exit 1; }
[ "$(grep -c '^diff --git a/frameworks/base/core/java/android/app/SystemServiceRegistry.java' "$patch")" -eq 1 ]
[ "$(grep -c '^diff --git ' "$patch")" -eq 1 ]
grep -F '+import android.os.SELinux;' "$patch" >/dev/null
grep -F '+import android.os.SystemProperties;' "$patch" >/dev/null
grep -F 'private static boolean shouldSuppressRoydPreBootServiceNotFound() {' "$patch" >/dev/null
grep -F '"1".equals(System.getenv("ROYD_CONTAINER")) && !SELinux.isSELinuxEnabled()' "$patch" >/dev/null
grep -F '!SystemProperties.getBoolean("sys.boot_completed", false);' "$patch" >/dev/null
[ "$(grep -c 'if (shouldSuppressRoydPreBootServiceNotFound()) {' "$patch")" -eq 2 ]
grep -F 'Slog.wtf(TAG, "Manager wrapper not available: " + name);' "$patch" >/dev/null
grep -F 'Log.wtf(TAG, e.getMessage(), e);' "$patch" >/dev/null

# The patch changes only reporting before boot completion. It must preserve the stock null result,
# post-boot WTF sites and service-fetch exception handling.
! grep -Eq '^[+-].*(fetcher\.getService|createService\(ctx\)|catch \(ServiceNotFoundException)' "$patch" || {
  echo 'pre-boot service patch changes service lookup behaviour' >&2
  exit 1
}

printf '%s\n' 'Android 15 pre-boot service WTF container contract passed'
