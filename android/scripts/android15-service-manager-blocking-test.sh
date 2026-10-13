#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
patch="$root/android/patches/android-15.0.0_r36/0035-framework-allow-blocking-native-service-manager.patch"

[ -f "$patch" ] || { echo 'missing Android 15 ServiceManager blocking patch' >&2; exit 1; }
[ "$(grep -c '^diff --git a/frameworks/base/core/java/android/os/ServiceManagerNative.java' "$patch")" -eq 1 ]
[ "$(grep -c '^diff --git ' "$patch")" -eq 1 ]
grep -F 'mServiceManager = IServiceManager.Stub.asInterface(' "$patch" >/dev/null
grep -F 'Binder.allowBlocking(this.getNativeServiceManager()));' "$patch" >/dev/null
grep -F -- '-        mServiceManager = IServiceManager.Stub.asInterface(this.getNativeServiceManager());' \
  "$patch" >/dev/null

# ServiceManager's native AIDL proxy performs required synchronous lookups. Mark only that proxy
# as blocking-safe, while retaining the legacy proxy, lookup methods and their return values.
if grep -Eq '^-.*(return mServiceManager|mRemote = remote|public IBinder asBinder)' "$patch"; then
  echo 'ServiceManager blocking patch changes the stock proxy or lookup path' >&2
  exit 1
fi

printf '%s\n' 'Android 15 native ServiceManager blocking contract passed'
