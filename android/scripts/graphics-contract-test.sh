#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
android_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

check_version() {
  version=$1
  composer=$2
  allocator=$3
  mapper=$4
  env_file="$android_dir/versions/$version.env"
  actual_composer=$(sh -c '. "$1"; printf "%s" "$ANDROID_GRAPHICS_COMPOSER"' sh "$env_file")
  actual_allocator=$(sh -c '. "$1"; printf "%s" "$ANDROID_GRAPHICS_ALLOCATOR"' sh "$env_file")
  actual_mapper=$(sh -c '. "$1"; printf "%s" "${ANDROID_GRAPHICS_MAPPER:-}"' sh "$env_file")
  [ "$actual_composer" = "$composer" ] || fail "Android $version graphics composer mismatch: $actual_composer"
  [ "$actual_allocator" = "$allocator" ] || fail "Android $version graphics allocator mismatch: $actual_allocator"
  [ "$actual_mapper" = "$mapper" ] || fail "Android $version graphics mapper mismatch: $actual_mapper"
}

check_version 8.0 2.1 gralloc0-memfd ''
check_version 8.1 2.1 gralloc0-memfd ''
check_version 9 2.2 gralloc0-memfd ''
check_version 10 2.3 gralloc0-memfd ''
for version in 11 12 13 14; do
  check_version "$version" 2.4 gralloc0-memfd ''
done
check_version 15 2.4 aidl2-stablec5-memfd stablec5-royd
for version in 16 17; do
  check_version "$version" 2.4 gralloc0-memfd ''
done

legacy_bp="$android_dir/royd/vendor/royd/Android.bp"
legacy_gralloc="$android_dir/royd/vendor/royd/gralloc/gralloc_royd.cpp"
modern="$android_dir/graphics/allocator-aidl2"
allocator="$modern/allocator/Allocator.cpp"
mapper="$modern/mapper/Mapper.cpp"
modern_bp="$modern/Android.bp"

# Legacy contract remains available for Android versions that still select it.
grep -Fq 'name: "gralloc.royd"' "$legacy_bp"
grep -Fq 'SYS_memfd_create' "$legacy_gralloc"
grep -Fq 'const_cast<uint32_t&>(device->flags) = 0;' "$legacy_gralloc"

# Android 15's software allocator is repository-owned and implements the
# allocator V2 plus stable-C mapper V5 boundary without emulator dependencies.
grep -Fq 'name: "android.hardware.graphics.allocator-service.royd"' "$modern_bp"
grep -Fq 'stem: "android.hardware.graphics.allocator-service"' "$modern_bp"
grep -Fq 'defaults: ["android.hardware.graphics.allocator-ndk_shared"]' "$modern_bp"
grep -Fq 'name: "mapper.royd"' "$modern_bp"
grep -Fq 'libimapper_providerutils' "$modern_bp"
grep -Fq 'SYS_memfd_create' "$allocator"
grep -Fq 'getIMapperLibrarySuffix' "$allocator"
grep -Fq '*suffix = "royd";' "$allocator"
grep -Fq 'allocate2(' "$allocator"
grep -Fq 'isSupported(' "$allocator"
grep -Fq 'ANDROID_HAL_STABLEC_VERSION = AIMAPPER_VERSION_5' "$mapper"
grep -Fq 'ANDROID_HAL_MAPPER_VERSION = AIMAPPER_VERSION_5' "$mapper"
grep -Fq 'AIMapper_loadIMapper' "$mapper"
grep -Fq 'StandardMetadataType::STRIDE' "$mapper"
grep -Fq "return fourcc('A', 'B', '2', '4');" "$mapper" || fail 'mapper must report RGBA_8888 as DRM ABGR8888'
grep -Fq "case PixelFormat::YV12:" "$allocator" || fail 'allocator must implement Android YV12'
grep -Fq 'descriptor.width & 1' "$allocator" || fail 'YV12 allocator must reject odd widths'
grep -Fq 'descriptor.height & 1' "$allocator" || fail 'YV12 allocator must reject odd heights'
grep -Fq 'align16(static_cast<uint64_t>(descriptor.width), &stride)' "$allocator" || fail 'YV12 allocator must align the Y stride to 16 pixels'
grep -Fq 'align16(stride / 2, &chromaStride)' "$allocator" || fail 'YV12 allocator must align chroma stride to 16 pixels'
grep -Fq "return fourcc('Y', 'V', '1', '2');" "$mapper" || fail 'mapper must report YV12 as DRM YVU420'
grep -Fq 'crPlane.horizontalSubsampling = 2;' "$mapper" || fail 'YV12 Cr plane must report 4:2:0 horizontal subsampling'
grep -Fq 'crPlane.verticalSubsampling = 2;' "$mapper" || fail 'YV12 Cr plane must report 4:2:0 vertical subsampling'
grep -Fq 'cbPlane.offsetInBytes = ySize + chromaSize;' "$mapper" || fail 'YV12 Cb plane must follow the Cr plane'
! grep -Fq 'return encode(static_cast<uint32_t>(0));' "$mapper" || fail 'mapper must not publish zero as the generic pixel-format FOURCC'
for unsupported_usage in FRONT_BUFFER VIDEO_ENCODER CAMERA_OUTPUT CAMERA_INPUT SENSOR_DIRECT_DATA; do
  ! grep -Fq "BufferUsage::$unsupported_usage" "$allocator" || fail "allocator must not advertise unvalidated $unsupported_usage usage"
done
for type in DATASPACE BLEND_MODE SMPTE2086 CTA861_3; do
  grep -Fq "case StandardMetadataType::$type:" "$mapper" || fail "stable-C mapper does not advertise required setter $type"
done
! grep -ERiq 'cuttlefish|goldfish|ranchu|qemu' "$modern" || fail 'modern software allocator contains a prohibited runtime dependency/reference'

grep -Fq 'ifeq ($(ROYD_GRAPHICS_ALLOCATOR),aidl2-stablec5-memfd)' "$android_dir/graphics/software.mk"
grep -Fq 'android.hardware.graphics.allocator-service.royd' "$android_dir/graphics/software.mk"
grep -Fq 'mapper.royd' "$android_dir/graphics/software.mk"
grep -Fq 'ro.hardware.hwcomposer=default' "$android_dir/graphics/software.mk"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM
mkdir -p "$work/build" "$work/external/minigbm" "$work/external/mesa3d"

ROYD_ANDROID_VERSION=15 "$script_dir/install-royd.sh" "$work" standard >/dev/null
grep -Fxq 'ROYD_GRAPHICS_ALLOCATOR := aidl2-stablec5-memfd' "$work/vendor/royd/version.mk"
grep -Fxq 'ROYD_GRAPHICS_MAPPER := stablec5-royd' "$work/vendor/royd/version.mk"
grep -Fq 'ro.vendor.royd.graphics_allocator=aidl2-stablec5-memfd' "$work/vendor/royd/version.mk"
grep -Fq 'ro.vendor.royd.graphics_mapper=stablec5-royd' "$work/vendor/royd/version.mk"
grep -Fq 'PRODUCT_PACKAGES += android.hardware.graphics.composer@2.4-service' "$work/vendor/royd/version.mk"
grep -Fq 'ro.vendor.royd.graphics_backend=software' "$work/vendor/royd/graphics_backend.mk"
grep -Fq 'android.hardware.graphics.allocator-service.royd' "$work/vendor/royd/graphics_backend.mk"
test -f "$work/vendor/royd/graphics_allocator/allocator/Allocator.cpp"
test -f "$work/vendor/royd/graphics_allocator/mapper/Mapper.cpp"
grep -Fq 'case PixelFormat::YV12:' "$work/vendor/royd/graphics_allocator/allocator/Allocator.cpp" || fail 'installed allocator lost YV12 support'
grep -Fq 'ANDROID_HAL_MAPPER_VERSION = AIMAPPER_VERSION_5' "$work/vendor/royd/graphics_allocator/mapper/Mapper.cpp" || fail 'installed mapper lost Android 15 VTS version symbol'
grep -Fxq 'SYSTEM_EXT_PRIVATE_SEPOLICY_DIRS += device/royd/sepolicy/system_ext/private' "$work/device/royd/BoardConfigVersion.mk"
grep -Fxq 'mapper/royd    u:object_r:hal_graphics_mapper_service:s0' "$work/device/royd/sepolicy/system_ext/private/service_contexts"

# Android 14 remains on the legacy allocator until its exact graphics-family
# boundary is researched separately.
rm -rf "$work/device/royd" "$work/vendor/royd"
ROYD_ANDROID_VERSION=14 "$script_dir/install-royd.sh" "$work" standard >/dev/null
grep -Fxq 'ROYD_GRAPHICS_ALLOCATOR := gralloc0-memfd' "$work/vendor/royd/version.mk"
! grep -Fq 'ROYD_GRAPHICS_MAPPER :=' "$work/vendor/royd/version.mk" || fail 'Android 14 unexpectedly selects stable-C mapper'
test ! -e "$work/vendor/royd/graphics_allocator"
! grep -Fq 'SYSTEM_EXT_PRIVATE_SEPOLICY_DIRS' "$work/device/royd/BoardConfigVersion.mk" || fail 'Android 14 unexpectedly selects mapper service policy'

printf '%s\n' 'Android graphics contract test passed'
