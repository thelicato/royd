#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
android_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)

check_version() {
  version=$1
  composer=$2
  env_file="$android_dir/versions/$version.env"
  actual_composer=$(sh -c '. "$1"; printf "%s" "$ANDROID_GRAPHICS_COMPOSER"' sh "$env_file")
  actual_allocator=$(sh -c '. "$1"; printf "%s" "$ANDROID_GRAPHICS_ALLOCATOR"' sh "$env_file")
  [ "$actual_composer" = "$composer" ] || {
    printf 'error: Android %s graphics composer mismatch: %s\n' "$version" "$actual_composer" >&2
    exit 1
  }
  [ "$actual_allocator" = gralloc0-memfd ] || {
    printf 'error: Android %s graphics allocator mismatch: %s\n' "$version" "$actual_allocator" >&2
    exit 1
  }
}

check_version 8.0 2.1
check_version 8.1 2.1
check_version 9 2.2
check_version 10 2.3
for version in 11 12 13 14 15 16 17; do
  check_version "$version" 2.4
done

grep -Fq 'name: "gralloc.royd"' "$android_dir/royd/vendor/royd/Android.bp"
grep -Fq 'SYS_memfd_create' "$android_dir/royd/vendor/royd/gralloc/gralloc_royd.cpp"
grep -Fq 'GRALLOC_HARDWARE_FB0' "$android_dir/royd/vendor/royd/gralloc/gralloc_royd.cpp"
grep -Fq 'const_cast<uint32_t&>(device->flags) = 0;' "$android_dir/royd/vendor/royd/gralloc/gralloc_royd.cpp"
grep -Fq 'const_cast<uint32_t&>(device->width)' "$android_dir/royd/vendor/royd/gralloc/gralloc_royd.cpp"
grep -Fq 'const_cast<uint32_t&>(device->height)' "$android_dir/royd/vendor/royd/gralloc/gralloc_royd.cpp"
grep -Fq 'const_cast<int&>(device->stride)' "$android_dir/royd/vendor/royd/gralloc/gralloc_royd.cpp"
grep -Fq 'const_cast<int&>(device->format)' "$android_dir/royd/vendor/royd/gralloc/gralloc_royd.cpp"
grep -Fq 'const_cast<float&>(device->xdpi)' "$android_dir/royd/vendor/royd/gralloc/gralloc_royd.cpp"
grep -Fq 'const_cast<float&>(device->ydpi)' "$android_dir/royd/vendor/royd/gralloc/gralloc_royd.cpp"
grep -Fq 'const_cast<float&>(device->fps)' "$android_dir/royd/vendor/royd/gralloc/gralloc_royd.cpp"
grep -Fq 'const_cast<int&>(device->minSwapInterval)' "$android_dir/royd/vendor/royd/gralloc/gralloc_royd.cpp"
grep -Fq 'const_cast<int&>(device->maxSwapInterval)' "$android_dir/royd/vendor/royd/gralloc/gralloc_royd.cpp"
grep -Fq 'ro.hardware.gralloc=royd' "$android_dir/graphics/software.mk"
grep -Fq 'ro.hardware.hwcomposer=default' "$android_dir/graphics/software.mk"
grep -Fq 'ro.hardware.egl=mesa' "$android_dir/graphics/host-gpu-generic.mk"
grep -Fq 'ANDROID_GRAPHICS_COMPOSER' "$android_dir/scripts/install-royd.sh"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM
mkdir -p "$work/build" "$work/external/minigbm" "$work/external/mesa3d"
ROYD_ANDROID_VERSION=15 "$script_dir/install-royd.sh" "$work" standard >/dev/null
grep -Fq 'PRODUCT_PACKAGES += android.hardware.graphics.composer@2.4-service' "$work/vendor/royd/version.mk"
grep -Fq 'ro.vendor.royd.graphics_composer=2.4' "$work/vendor/royd/version.mk"
grep -Fq 'ro.vendor.royd.graphics_backend=software' "$work/vendor/royd/graphics_backend.mk"
grep -Fq 'gralloc.royd' "$work/vendor/royd/graphics_backend.mk"
test -f "$work/vendor/royd/gralloc/gralloc_royd.cpp"
test -x "$work/vendor/royd/bin/royd-graphics-setup"
ROYD_ANDROID_VERSION=15 ROYD_GRAPHICS_BACKEND=host-gpu-generic ROYD_GRAPHICS_ARCH=x86_64 "$script_dir/install-royd.sh" "$work" standard >/dev/null
grep -Fq 'ro.vendor.royd.graphics_backend=host-gpu-generic' "$work/vendor/royd/graphics_backend.mk"
grep -Fq 'gralloc.minigbm' "$work/vendor/royd/graphics_backend.mk"

printf '%s\n' 'Android graphics contract test passed'
