#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
patch="$root/android/patches/android-15.0.0_r36/0006-keystore2-support-royd-container-selinux-disabled.patch"

[ -f "$patch" ] || { echo 'missing Android 15 royd Keystore2 patch' >&2; exit 1; }
[ "$(grep -c '^diff --git a/system/security/keystore2/' "$patch")" -eq 10 ]
[ "$(grep -c '^+            crate::utils::binder_features(BinderFeatures {' "$patch")" -eq 8 ]
[ "$(grep -c '^+                set_requesting_sid: true, ..BinderFeatures::default()' "$patch")" -eq 8 ]
[ "$(grep -c 'calling_sid.is_none() && royd_missing_sid_fallback_enabled()' "$patch")" -eq 3 ]
grep -F 'std::env::var("ROYD_CONTAINER").as_deref() == Ok("1") && selinux::is_selinux_enabled() <= 0' "$patch" >/dev/null
grep -F 'features.set_requesting_sid = false;' "$patch" >/dev/null
grep -F 'const SYSTEM_UID: u32 = 1000;' "$patch" >/dev/null
grep -F 'const LOCK_SETTINGS_NAMESPACE: i64 = 103;' "$patch" >/dev/null
grep -F 'matches!(perm, KeystorePerm::Unlock | KeystorePerm::ChangeUser)' "$patch" >/dev/null
grep -F 'key.domain == Domain::SELINUX' "$patch" >/dev/null
grep -F 'key.nspace == LOCK_SETTINGS_NAMESPACE' "$patch" >/dev/null
grep -F 'KeyPerm::Delete' "$patch" >/dev/null
grep -F 'KeyPerm::GetInfo' "$patch" >/dev/null
grep -F 'KeyPerm::Rebind' "$patch" >/dev/null
grep -F 'KeyPerm::Update' "$patch" >/dev/null
grep -F 'KeyPerm::Use' "$patch" >/dev/null
grep -F 'missing-SID grant permission fallback' "$patch" | grep -F 'decision=deny' >/dev/null
grep -F 'permission::check_keystore_permission(' "$patch" >/dev/null
grep -F 'permission::check_grant_permission(' "$patch" >/dev/null
grep -F 'permission::check_key_permission(' "$patch" >/dev/null

if grep -Fq 'ROYD_DIAG' "$patch"; then
  echo 'permanent Keystore2 patch retains a diagnostic-only marker' >&2
  exit 1
fi

printf '%s\n' 'Android 15 Keystore2 container contract passed'
