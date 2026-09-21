#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
android_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)

check_version() {
  version=$1
  tag=$2
  x86_target=$3
  arm_target=$4
  status=$5
  builder=$6
  partitions=$7
  memory_compat=$8
  graphics_composer=$9
  host_gpu=${10}
  graphics_allocator=${11}
  graphics_mapper=${12}

  env_file="$android_dir/versions/$version.env"
  actual_tag=$(sh -c '. "$1"; printf "%s" "$AOSP_TAG"' sh "$env_file")
  actual_status=$(sh -c '. "$1"; printf "%s" "$ANDROID_SUPPORT_STATUS"' sh "$env_file")
  actual_builder=$(sh -c '. "$1"; printf "%s" "$ANDROID_BUILDER_FAMILY"' sh "$env_file")
  actual_partitions=$(sh -c '. "$1"; printf "%s" "$ANDROID_REQUIRED_PARTITIONS"' sh "$env_file")
  actual_memory=$(sh -c '. "$1"; printf "%s" "$ANDROID_MEMORY_COMPAT"' sh "$env_file")
  actual_graphics_composer=$(sh -c '. "$1"; printf "%s" "$ANDROID_GRAPHICS_COMPOSER"' sh "$env_file")
  actual_host_gpu=$(sh -c '. "$1"; printf "%s" "$ANDROID_HOST_GPU_SUPPORTED"' sh "$env_file")
  actual_graphics_allocator=$(sh -c '. "$1"; printf "%s" "$ANDROID_GRAPHICS_ALLOCATOR"' sh "$env_file")
  actual_graphics_mapper=$(sh -c '. "$1"; printf "%s" "${ANDROID_GRAPHICS_MAPPER:-}"' sh "$env_file")
  actual_x86=$(ROYD_ANDROID_VERSION="$version" "$script_dir/lunch-target.sh" x86_64)
  actual_arm=$(ROYD_ANDROID_VERSION="$version" "$script_dir/lunch-target.sh" arm64)

  [ "$actual_tag" = "$tag" ] || { printf 'error: Android %s tag mismatch\n' "$version" >&2; exit 1; }
  [ "$actual_status" = "$status" ] || { printf 'error: Android %s status mismatch\n' "$version" >&2; exit 1; }
  [ "$actual_builder" = "$builder" ] || { printf 'error: Android %s builder mismatch\n' "$version" >&2; exit 1; }
  [ "$actual_partitions" = "$partitions" ] || { printf 'error: Android %s partition contract mismatch\n' "$version" >&2; exit 1; }
  [ "$actual_memory" = "$memory_compat" ] || { printf 'error: Android %s memory compatibility mismatch\n' "$version" >&2; exit 1; }
  [ "$actual_graphics_composer" = "$graphics_composer" ] || { printf 'error: Android %s graphics composer mismatch\n' "$version" >&2; exit 1; }
  [ "$actual_host_gpu" = "$host_gpu" ] || { printf 'error: Android %s host GPU support mismatch\n' "$version" >&2; exit 1; }
  [ "$actual_graphics_allocator" = "$graphics_allocator" ] || { printf 'error: Android %s graphics allocator mismatch\n' "$version" >&2; exit 1; }
  [ "$actual_graphics_mapper" = "$graphics_mapper" ] || { printf 'error: Android %s graphics mapper mismatch\n' "$version" >&2; exit 1; }
  [ "$actual_x86" = "$x86_target" ] || { printf 'error: Android %s x86_64 lunch target mismatch: %s\n' "$version" "$actual_x86" >&2; exit 1; }
  [ "$actual_arm" = "$arm_target" ] || { printf 'error: Android %s arm64 lunch target mismatch: %s\n' "$version" "$actual_arm" >&2; exit 1; }
}

check_version 8.0 android-8.0.0_r36 royd_x86_64-userdebug royd_arm64-userdebug legacy-configured legacy "system vendor" libcutils-memfd-overlay 2.1 0 gralloc0-memfd ''
check_version 8.1 android-8.1.0_r81 royd_x86_64-userdebug royd_arm64-userdebug legacy-configured legacy "system vendor" libcutils-memfd-overlay 2.1 0 gralloc0-memfd ''
check_version 9 android-9.0.0_r61 royd_x86_64-userdebug royd_arm64-userdebug legacy-configured legacy "system vendor" libcutils-memfd-overlay 2.2 0 gralloc0-memfd ''
check_version 10 android-10.0.0_r47 royd_x86_64-userdebug royd_arm64-userdebug legacy-configured legacy "system vendor product" libcutils-memfd-overlay 2.3 1 gralloc0-memfd ''
check_version 11 android-11.0.0_r48 royd_x86_64-userdebug royd_arm64-userdebug configured modern "system vendor system_ext product" native-memfd 2.4 1 gralloc0-memfd ''
check_version 12 android-12.0.0_r34 royd_x86_64-userdebug royd_arm64-userdebug configured modern "system vendor system_ext product" native-memfd 2.4 1 gralloc0-memfd ''
check_version 13 android-13.0.0_r75 royd_x86_64-userdebug royd_arm64-userdebug configured modern "system vendor system_ext product" native-memfd 2.4 1 gralloc0-memfd ''
check_version 14 android-14.0.0_r14 royd_x86_64-userdebug royd_arm64-userdebug configured modern "system vendor system_ext product" native-memfd 2.4 1 gralloc0-memfd ''
check_version 15 android-15.0.0_r36 royd_x86_64-bp1a-userdebug royd_arm64-bp1a-userdebug baseline modern "system vendor system_ext product" native-memfd 2.4 1 aidl2-stablec5-memfd stablec5-royd
check_version 16 android-16.0.0_r4 royd_x86_64-bp4a-userdebug royd_arm64-bp4a-userdebug configured modern "system vendor system_ext product" native-memfd 2.4 1 gralloc0-memfd ''
check_version 17 android-17.0.0_r1 royd_x86_64-cp2a-userdebug royd_arm64-cp2a-userdebug configured modern "system vendor system_ext product" native-memfd 2.4 1 gralloc0-memfd ''

expected=$(
  cat <<'EOF2'
8.0
8.1
9
10
11
12
13
14
15
16
17
EOF2
)
actual=$("$script_dir/version-list.sh")
[ "$actual" = "$expected" ] || {
  printf 'error: Android version list mismatch\nexpected:\n%s\nactual:\n%s\n' "$expected" "$actual" >&2
  exit 1
}

printf '%s\n' 'Android version matrix test passed'
