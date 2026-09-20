#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1091
. "$script_dir/common.sh"

src=${1:-$(source_dir)}
profile=${2:-${ROYD_ANDROID_PROFILE:-standard}}
profile=$($script_dir/profile.sh "$profile")
royd_src="$android_dir/royd"
device_src="$royd_src/device/royd"
vendor_src="$royd_src/vendor/royd"
device_dst="$src/device/royd"
vendor_dst="$src/vendor/royd"
profile_src="$android_dir/profiles/$profile.mk"
profile_dst="$vendor_dst/profile.mk"
compat_src="$android_dir/compat/$ANDROID_PRODUCT_FAMILY"

[ -d "$src/build" ] || fail "AOSP source tree not found at $src"
[ -d "$device_src" ] || fail "royd device source not found at $device_src"
[ -d "$vendor_src" ] || fail "royd vendor source not found at $vendor_src"
[ -f "$profile_src" ] || fail "Android image profile not found at $profile_src"
[ -d "$compat_src" ] || fail "Android compatibility family not found at $compat_src"

printf 'Installing repository-owned royd Android projects with profile %s\n' "$profile"
rm -rf "$device_dst" "$vendor_dst"
mkdir -p "$device_dst" "$vendor_dst"
cp -a "$device_src/." "$device_dst/"
cp -a "$vendor_src/." "$vendor_dst/"
cp "$profile_src" "$profile_dst"
cp "$compat_src/product.mk" "$device_dst/container_version.mk"
cp "$compat_src/BoardConfigVersion.mk" "$device_dst/BoardConfigVersion.mk"
cp "$compat_src/vendor.mk" "$vendor_dst/version.mk"
printf 'PRODUCT_VENDOR_PROPERTIES += ro.vendor.royd.memory_compat=%s\n' "$ANDROID_MEMORY_COMPAT" >> "$vendor_dst/version.mk"

"$script_dir/install-memory-compat.sh" "$src"
