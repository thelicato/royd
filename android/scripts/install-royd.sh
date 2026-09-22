#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1091
. "$script_dir/common.sh"

require_command sha256sum

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
profile_policy_dst="$vendor_dst/profile_policy.mk"
profile_packages_dst="$vendor_dst/profile-packages.txt"
hal_profile=${ROYD_HAL_PROFILE:-graphical}
hal_profile=$("$script_dir/hal-profile.sh" "$hal_profile")
hal_profile_src="$android_dir/hal-profiles/$hal_profile.mk"
hal_profile_dst="$vendor_dst/hal_profile.mk"
graphics_backend=${ROYD_GRAPHICS_BACKEND:-software}
graphics_arch=${ROYD_GRAPHICS_ARCH:-}
graphics_backend=$(ROYD_GRAPHICS_ARCH="$graphics_arch" "$script_dir/graphics-backend.sh" "$graphics_backend" "$graphics_arch")
graphics_backend_src="$android_dir/graphics/$graphics_backend.mk"
graphics_backend_dst="$vendor_dst/graphics_backend.mk"
graphics_composer=$ANDROID_GRAPHICS_COMPOSER
graphics_allocator=$ANDROID_GRAPHICS_ALLOCATOR
graphics_mapper=${ANDROID_GRAPHICS_MAPPER:-}
modern_graphics_src="$android_dir/graphics/allocator-aidl2"
modern_graphics_dst="$vendor_dst/graphics_allocator"
modern_composer_src="$android_dir/graphics/composer-aidl4"
modern_composer_dst="$vendor_dst/graphics_composer"
compat_src="$android_dir/compat/$ANDROID_PRODUCT_FAMILY"
device_manifest=${ANDROID_DEVICE_MANIFEST:-}
if [ -n "$device_manifest" ]; then
  case "$device_manifest" in
    /*|..|../*|*/../*|*/..) fail "invalid Android device manifest path: $device_manifest" ;;
  esac
  device_manifest_src="$device_src/$device_manifest"
else
  device_manifest_src=
fi

[ -d "$src/build" ] || fail "AOSP source tree not found at $src"
[ -d "$device_src" ] || fail "royd device source not found at $device_src"
[ -d "$vendor_src" ] || fail "royd vendor source not found at $vendor_src"
[ -f "$profile_src" ] || fail "Android image profile not found at $profile_src"
[ -f "$hal_profile_src" ] || fail "Android HAL profile not found at $hal_profile_src"
[ -f "$graphics_backend_src" ] || fail "Android graphics backend not found at $graphics_backend_src"
case "$graphics_composer" in
  2.1|2.2|2.3|2.4) ;;
  aidl4-client)
    [ -d "$modern_composer_src" ] || fail "modern graphics composer source not found at $modern_composer_src"
    ;;
  *) fail "unsupported Android graphics composer contract: $graphics_composer" ;;
esac
case "$graphics_allocator" in
  gralloc0-memfd)
    [ -z "$graphics_mapper" ] || fail "legacy allocator unexpectedly declares a stable-C mapper: $graphics_mapper"
    ;;
  aidl2-stablec5-memfd)
    [ "$graphics_mapper" = stablec5-royd ] || fail "modern allocator requires ANDROID_GRAPHICS_MAPPER=stablec5-royd"
    [ -d "$modern_graphics_src" ] || fail "modern graphics allocator source not found at $modern_graphics_src"
    ;;
  *) fail "unsupported Android graphics allocator contract: $graphics_allocator" ;;
esac
[ -d "$compat_src" ] || fail "Android compatibility family not found at $compat_src"
[ -z "$device_manifest_src" ] || [ -f "$device_manifest_src" ] || fail "Android device manifest not found at $device_manifest_src"
case "$graphics_backend" in
  host-gpu-*)
    [ -d "$src/external/minigbm" ] || fail "host GPU backend requires AOSP external/minigbm"
    [ -d "$src/external/mesa3d" ] || fail "host GPU backend requires AOSP external/mesa3d"
    ;;
esac

printf 'Installing repository-owned royd Android projects with image profile %s, HAL profile %s and graphics backend %s\n' "$profile" "$hal_profile" "$graphics_backend"
rm -rf "$device_dst" "$vendor_dst"
mkdir -p "$device_dst" "$vendor_dst"
cp -a "$device_src/." "$device_dst/"
cp -a "$vendor_src/." "$vendor_dst/"
if [ "$graphics_allocator" = aidl2-stablec5-memfd ]; then
  cp -a "$modern_graphics_src" "$modern_graphics_dst"
fi
if [ "$graphics_composer" = aidl4-client ]; then
  cp -a "$modern_composer_src" "$modern_composer_dst"
fi
cp "$profile_src" "$profile_dst"
profile_policy=$(ROYD_ANDROID_VERSION="$ANDROID_VERSION" "$script_dir/profile-policy.sh" "$profile")
ROYD_ANDROID_VERSION="$ANDROID_VERSION" "$script_dir/profile-packages.sh" "$profile" > "$profile_packages_dst"
profile_policy_sha256=$(sha256sum "$profile_packages_dst" | awk '{print $1}')
{
  printf '# Generated from repository-owned Android image profile policy.\n'
  printf 'ROYD_PROFILE_POLICY := %s\n' "$profile_policy"
  printf 'ROYD_PROFILE_POLICY_SHA256 := %s\n' "$profile_policy_sha256"
  if [ -s "$profile_packages_dst" ]; then
    printf 'ROYD_MINIMAL_PACKAGES := %s\n' "$(tr '\n' ' ' < "$profile_packages_dst" | sed 's/[[:space:]]*$//')"
  else
    printf 'ROYD_MINIMAL_PACKAGES :=\n'
  fi
  printf 'PRODUCT_VENDOR_PROPERTIES += ro.vendor.royd.profile_policy=%s\n' "$profile_policy"
  printf 'PRODUCT_VENDOR_PROPERTIES += ro.vendor.royd.profile_policy_sha256=%s\n' "$profile_policy_sha256"
} > "$profile_policy_dst"
cp "$hal_profile_src" "$hal_profile_dst"
cp "$graphics_backend_src" "$graphics_backend_dst"
cp "$compat_src/product.mk" "$device_dst/container_version.mk"
cp "$compat_src/BoardConfigVersion.mk" "$device_dst/BoardConfigVersion.mk"
if [ -n "$device_manifest" ]; then
  printf 'DEVICE_MANIFEST_FILE := device/royd/%s\n' "$device_manifest" >> "$device_dst/BoardConfigVersion.mk"
fi
if [ "$graphics_allocator" = aidl2-stablec5-memfd ]; then
  printf 'SYSTEM_EXT_PRIVATE_SEPOLICY_DIRS += device/royd/sepolicy/system_ext/private\n' >> "$device_dst/BoardConfigVersion.mk"
fi
if [ "$graphics_composer" = aidl4-client ]; then
  printf 'BOARD_VENDOR_SEPOLICY_DIRS += device/royd/sepolicy/vendor\n' >> "$device_dst/BoardConfigVersion.mk"
fi
cp "$compat_src/vendor.mk" "$vendor_dst/version.mk"
printf 'ROYD_GRAPHICS_ALLOCATOR := %s\n' "$graphics_allocator" >> "$vendor_dst/version.mk"
printf 'PRODUCT_VENDOR_PROPERTIES += ro.vendor.royd.graphics_allocator=%s\n' "$graphics_allocator" >> "$vendor_dst/version.mk"
if [ -n "$graphics_mapper" ]; then
  printf 'ROYD_GRAPHICS_MAPPER := %s\n' "$graphics_mapper" >> "$vendor_dst/version.mk"
  printf 'PRODUCT_VENDOR_PROPERTIES += ro.vendor.royd.graphics_mapper=%s\n' "$graphics_mapper" >> "$vendor_dst/version.mk"
fi
printf 'PRODUCT_VENDOR_PROPERTIES += ro.vendor.royd.memory_compat=%s\n' "$ANDROID_MEMORY_COMPAT" >> "$vendor_dst/version.mk"
printf 'ROYD_GRAPHICS_COMPOSER := %s\n' "$graphics_composer" >> "$vendor_dst/version.mk"
case "$graphics_composer" in
  aidl4-client) ;;
  *) printf 'PRODUCT_PACKAGES += android.hardware.graphics.composer@%s-service\n' "$graphics_composer" >> "$vendor_dst/version.mk" ;;
esac
printf 'PRODUCT_VENDOR_PROPERTIES += ro.vendor.royd.graphics_composer=%s\n' "$graphics_composer" >> "$vendor_dst/version.mk"

"$script_dir/install-memory-compat.sh" "$src"
