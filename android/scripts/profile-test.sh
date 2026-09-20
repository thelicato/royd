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
[ -f "$tmp/vendor/royd/Android.bp" ]
grep -Fq 'ro.vendor.royd.image_profile=standard' "$tmp/vendor/royd/profile.mk"
grep -Fq 'royd-binder-alloc' "$tmp/vendor/royd/Android.bp"

"$script_dir/install-royd.sh" "$tmp" minimal
grep -Fq 'ro.vendor.royd.image_profile=minimal' "$tmp/vendor/royd/profile.mk"
! grep -Fq 'ro.vendor.royd.image_profile=standard' "$tmp/vendor/royd/profile.mk"
[ "$(grep -Fc '$(call inherit-product, vendor/royd/royd.mk)' "$tmp/device/royd/royd_x86_64.mk")" -eq 1 ]
[ "$(grep -Fc '$(call inherit-product, vendor/royd/royd.mk)' "$tmp/device/royd/royd_arm64.mk")" -eq 1 ]

printf '%s\n' 'Android profile installation checks passed'
