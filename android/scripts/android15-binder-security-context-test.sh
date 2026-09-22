#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
patch="$root/android/patches/android-15.0.0_r36/0003-servicemanager-disable-binder-security-context-without-selinux.patch"

[ -f "$patch" ] || { echo 'missing Android 15 Binder security-context patch' >&2; exit 1; }

grep -F 'bool usesSelinux() const { return !mSkipSelinux; }' "$patch" >/dev/null
grep -F 'bool ProcessState::becomeContextManager()' "$patch" >/dev/null
grep -F 'return becomeContextManager(true);' "$patch" >/dev/null
grep -F 'bool ProcessState::becomeContextManager(bool requestSecurityContext)' "$patch" >/dev/null
grep -F '.flags = static_cast<__u32>(requestSecurityContext ? FLAT_BINDER_FLAG_TXN_SECURITY_CTX : 0),' "$patch" >/dev/null
grep -F 'const bool requestSecurityContext = access->usesSelinux();' "$patch" >/dev/null
grep -F 'manager->setRequestingSid(requestSecurityContext);' "$patch" >/dev/null
grep -F 'ps->becomeContextManager(requestSecurityContext)' "$patch" >/dev/null

# Preserve the existing zero-argument libbinder API and its normal Android behaviour.
if grep -Fq -- '-    [[nodiscard]] LIBBINDER_EXPORTED bool becomeContextManager();' "$patch"; then
  echo 'error: task 053 patch removes the existing libbinder context-manager API' >&2
  exit 1
fi
if grep -Fq -- '-        .flags = FLAT_BINDER_FLAG_TXN_SECURITY_CTX,' "$patch" && \
   ! grep -Fq 'return becomeContextManager(true);' "$patch"; then
  echo 'error: task 053 patch does not preserve security-context requests by default' >&2
  exit 1
fi

printf '%s\n' 'Android 15 Binder security-context container contract passed'
