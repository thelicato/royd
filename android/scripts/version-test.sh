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

  actual_tag=$(sh -c '. "$1"; printf "%s" "$AOSP_TAG"' sh "$android_dir/versions/$version.env")
  actual_status=$(sh -c '. "$1"; printf "%s" "$ANDROID_SUPPORT_STATUS"' sh "$android_dir/versions/$version.env")
  actual_x86=$(ROYD_ANDROID_VERSION="$version" "$script_dir/lunch-target.sh" x86_64)
  actual_arm=$(ROYD_ANDROID_VERSION="$version" "$script_dir/lunch-target.sh" arm64)

  [ "$actual_tag" = "$tag" ] || { printf 'error: Android %s tag mismatch\n' "$version" >&2; exit 1; }
  [ "$actual_status" = "$status" ] || { printf 'error: Android %s status mismatch\n' "$version" >&2; exit 1; }
  [ "$actual_x86" = "$x86_target" ] || { printf 'error: Android %s x86_64 lunch target mismatch: %s\n' "$version" "$actual_x86" >&2; exit 1; }
  [ "$actual_arm" = "$arm_target" ] || { printf 'error: Android %s arm64 lunch target mismatch: %s\n' "$version" "$actual_arm" >&2; exit 1; }
}

check_version 14 android-14.0.0_r14 royd_x86_64-userdebug royd_arm64-userdebug configured
check_version 15 android-15.0.0_r36 royd_x86_64-bp1a-userdebug royd_arm64-bp1a-userdebug baseline
check_version 16 android-16.0.0_r4 royd_x86_64-bp4a-userdebug royd_arm64-bp4a-userdebug configured
check_version 17 android-17.0.0_r1 royd_x86_64-cp2a-userdebug royd_arm64-cp2a-userdebug configured

if ROYD_ANDROID_VERSION=13 "$script_dir/lunch-target.sh" x86_64 >/dev/null 2>&1; then
  printf '%s\n' 'error: unsupported Android version was accepted' >&2
  exit 1
fi

printf '%s\n' 'Android version matrix test passed'
