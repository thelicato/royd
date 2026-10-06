#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
patch="$root/android/patches/android-15.0.0_r36/0016-init-preserve-container-output.patch"

[ -f "$patch" ] || { echo 'missing Android 15 init OCI output patch' >&2; exit 1; }
[ "$(grep -c '^diff --git a/system/core/init/util.cpp' "$patch")" -eq 1 ]
[ "$(grep -c '^diff --git ' "$patch")" -eq 1 ]
grep -F '+#include <selinux/selinux.h>' "$patch" >/dev/null
grep -F 'const char* royd_container = getenv("ROYD_CONTAINER");' "$patch" >/dev/null
grep -F 'strcmp(royd_container, "1") == 0 && is_selinux_enabled() <= 0;' "$patch" >/dev/null
grep -F 'const bool preserve_container_output = royd_container != nullptr &&' "$patch" >/dev/null
grep -F 'if (!preserve_container_output) {' "$patch" >/dev/null

# Stdin remains /dev/null and the stock output redirects remain present behind
# the narrow container gate. Descriptor closure and fatal open handling stay unchanged.
if grep -Eq '^[+-].*dup2\(fd, STDIN_FILENO\)' "$patch"; then
  echo 'init OCI output patch changes the stock stdin redirect' >&2
  exit 1
fi
grep -F 'dup2(fd, STDOUT_FILENO);' "$patch" >/dev/null
grep -F 'dup2(fd, STDERR_FILENO);' "$patch" >/dev/null
if grep -Eq '^[+-].*(PLOG\(FATAL\).*Couldn.t open /dev/null|if \(fd > STDERR_FILENO\) close\(fd\))' "$patch"; then
  echo 'init OCI output patch changes stock fatal or descriptor-close handling' >&2
  exit 1
fi

if grep -Fq 'ROYD_DIAG' "$patch"; then
  echo 'permanent init OCI output patch retains a diagnostic-only marker' >&2
  exit 1
fi

printf '%s\n' 'Android 15 init OCI output contract passed'
