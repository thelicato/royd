#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
patch="$root/android/patches/android-15.0.0_r36/0009-debug-support-hidden-kernel-config-without-selinux.patch"

[ -f "$patch" ] || { echo 'missing Android 15 royd Debug kernel-config patch' >&2; exit 1; }
[ "$(grep -c '^diff --git a/frameworks/base/core/jni/android_os_Debug.cpp' "$patch")" -eq 1 ]
[ "$(grep -c '^diff --git ' "$patch")" -eq 1 ]
grep -F '#include <selinux/selinux.h>' "$patch" >/dev/null
grep -F 'if (result != OK && royd_container != nullptr && strcmp(royd_container, "1") == 0 &&' "$patch" >/dev/null
grep -F 'is_selinux_enabled() <= 0) {' "$patch" >/dev/null
grep -F 'ROYD: /proc/config.gz unavailable with kernel SELinux disabled;' "$patch" >/dev/null
grep -F '+            cfg_state = CONFIG_UNSET;' "$patch" >/dev/null
grep -F '+            CHECK(result == OK) << "Kernel configs could not be fetched. b/151092221";' "$patch" >/dev/null
grep -F '+                    configs.find("CONFIG_VMAP_STACK");' "$patch" >/dev/null
grep -F '+            cfg_state = (it != configs.end() && it->second == "y") ? CONFIG_SET : CONFIG_UNSET;' "$patch" >/dev/null

if grep -Fq 'ROYD_DIAG' "$patch"; then
  echo 'permanent Debug kernel-config patch retains a diagnostic-only marker' >&2
  exit 1
fi

printf '%s\n' 'Android 15 Debug kernel-config container contract passed'
