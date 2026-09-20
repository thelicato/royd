#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1091
. "$script_dir/common.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM
mkdir -p "$tmp/build"

"$script_dir/install-royd.sh" "$tmp" standard
[ -f "$tmp/device/royd/AndroidProducts.mk" ]
[ -f "$tmp/device/royd/royd_x86_64.mk" ]
[ -f "$tmp/device/royd/container_common.mk" ]
[ -f "$tmp/device/royd/royd_x86_64/BoardConfig.mk" ]
[ -f "$tmp/device/royd/royd_arm64/BoardConfig.mk" ]
grep -Fq 'PRODUCT_DEVICE := royd_x86_64' "$tmp/device/royd/royd_x86_64.mk"
grep -Fq 'PRODUCT_DEVICE := royd_arm64' "$tmp/device/royd/royd_arm64.mk"
grep -Fq 'TARGET_NO_KERNEL := true' "$tmp/device/royd/royd_x86_64/BoardConfig.mk"
grep -Fq 'TARGET_NO_KERNEL := true' "$tmp/device/royd/royd_arm64/BoardConfig.mk"
! grep -R -Fq 'emulator_vendor.mk' "$tmp/device/royd"
[ -f "$tmp/vendor/royd/Android.bp" ]
grep -Fq 'ro.vendor.royd.image_profile=standard' "$tmp/vendor/royd/profile.mk"
grep -Fq 'ROYD_PROFILE_POLICY := standard-v1' "$tmp/vendor/royd/profile_policy.mk"
[ ! -s "$tmp/vendor/royd/profile-packages.txt" ]
grep -Fq 'royd-binder-alloc' "$tmp/vendor/royd/Android.bp"
grep -Fq 'royd-memfd-probe' "$tmp/vendor/royd/Android.bp"
grep -Fq 'ro.vendor.royd.memory_compat=native-memfd' "$tmp/vendor/royd/version.mk"

"$script_dir/install-royd.sh" "$tmp" minimal
grep -Fq 'ro.vendor.royd.image_profile=minimal' "$tmp/vendor/royd/profile.mk"
grep -Fq 'ROYD_PROFILE_POLICY := minimal-v2-modern' "$tmp/vendor/royd/profile_policy.mk"
grep -Fq 'Camera2' "$tmp/vendor/royd/profile-packages.txt"
grep -Fq 'PhotoTable' "$tmp/vendor/royd/profile-packages.txt"
! grep -Fq 'Settings' "$tmp/vendor/royd/profile-packages.txt"
grep -Fq 'profile-packages.txt' "$tmp/vendor/royd/royd.mk"
! grep -Fq 'ro.vendor.royd.image_profile=standard' "$tmp/vendor/royd/profile.mk"
[ "$(grep -Fc '$(call inherit-product, vendor/royd/royd.mk)' "$tmp/device/royd/royd_x86_64.mk")" -eq 1 ]
[ "$(grep -Fc '$(call inherit-product, vendor/royd/royd.mk)' "$tmp/device/royd/royd_arm64.mk")" -eq 1 ]

printf '%s\n' 'Android profile installation checks passed'
