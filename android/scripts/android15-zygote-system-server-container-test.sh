#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
patch="$root/android/patches/android-15.0.0_r36/0008-zygote-support-system-server-without-selinux.patch"

[ -f "$patch" ] || { echo 'missing Android 15 royd Zygote system_server patch' >&2; exit 1; }
[ "$(grep -c '^diff --git a/frameworks/base/core/jni/com_android_internal_os_Zygote.cpp' "$patch")" -eq 1 ]
[ "$(grep -c '^diff --git ' "$patch")" -eq 1 ]
grep -F 'if (IsRoydContainerWithoutSelinux()) {' "$patch" >/dev/null
grep -F 'ROYD: skipping system_server setcon because ROYD_CONTAINER=1 and kernel' "$patch" >/dev/null
grep -F '+                  "SELinux is disabled");' "$patch" >/dev/null
grep -F '+        } else if (selinux_android_setcon(kSystemServerLabel) != 0) {' "$patch" >/dev/null
grep -F 'fail_fn(CREATE_ERROR("selinux_android_setcon(%s)", kSystemServerLabel));' "$patch" >/dev/null

if grep -Eq '^[+-].*selinux_android_setcontext' "$patch"; then
  echo 'Zygote system_server patch changes the stock process context call' >&2
  exit 1
fi

if grep -Fq 'ROYD_DIAG' "$patch"; then
  echo 'permanent Zygote system_server patch retains a diagnostic-only marker' >&2
  exit 1
fi

printf '%s\n' 'Android 15 Zygote system_server container contract passed'

