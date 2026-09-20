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

  env_file="$android_dir/versions/$version.env"
  actual_tag=$(sh -c '. "$1"; printf "%s" "$AOSP_TAG"' sh "$env_file")
  actual_status=$(sh -c '. "$1"; printf "%s" "$ANDROID_SUPPORT_STATUS"' sh "$env_file")
  actual_builder=$(sh -c '. "$1"; printf "%s" "$ANDROID_BUILDER_FAMILY"' sh "$env_file")
  actual_partitions=$(sh -c '. "$1"; printf "%s" "$ANDROID_REQUIRED_PARTITIONS"' sh "$env_file")
  actual_memory=$(sh -c '. "$1"; printf "%s" "$ANDROID_MEMORY_COMPAT"' sh "$env_file")
  actual_x86=$(ROYD_ANDROID_VERSION="$version" "$script_dir/lunch-target.sh" x86_64)
  actual_arm=$(ROYD_ANDROID_VERSION="$version" "$script_dir/lunch-target.sh" arm64)

  [ "$actual_tag" = "$tag" ] || { printf 'error: Android %s tag mismatch\n' "$version" >&2; exit 1; }
  [ "$actual_status" = "$status" ] || { printf 'error: Android %s status mismatch\n' "$version" >&2; exit 1; }
  [ "$actual_builder" = "$builder" ] || { printf 'error: Android %s builder mismatch\n' "$version" >&2; exit 1; }
  [ "$actual_partitions" = "$partitions" ] || { printf 'error: Android %s partition contract mismatch\n' "$version" >&2; exit 1; }
  [ "$actual_memory" = "$memory_compat" ] || { printf 'error: Android %s memory compatibility mismatch\n' "$version" >&2; exit 1; }
  [ "$actual_x86" = "$x86_target" ] || { printf 'error: Android %s x86_64 lunch target mismatch: %s\n' "$version" "$actual_x86" >&2; exit 1; }
  [ "$actual_arm" = "$arm_target" ] || { printf 'error: Android %s arm64 lunch target mismatch: %s\n' "$version" "$actual_arm" >&2; exit 1; }
}

check_version 8.1 android-8.1.0_r81 royd_x86_64-userdebug royd_arm64-userdebug legacy-configured legacy "system vendor" ashmem-compat-required
check_version 9 android-9.0.0_r61 royd_x86_64-userdebug royd_arm64-userdebug legacy-configured legacy "system vendor" ashmem-compat-required
check_version 10 android-10.0.0_r47 royd_x86_64-userdebug royd_arm64-userdebug legacy-configured legacy "system vendor product" ashmem-transition
check_version 11 android-11.0.0_r48 royd_x86_64-userdebug royd_arm64-userdebug configured modern "system vendor system_ext product" memfd-capable
check_version 12 android-12.0.0_r34 royd_x86_64-userdebug royd_arm64-userdebug configured modern "system vendor system_ext product" memfd-capable
check_version 13 android-13.0.0_r75 royd_x86_64-userdebug royd_arm64-userdebug configured modern "system vendor system_ext product" memfd-capable
check_version 14 android-14.0.0_r14 royd_x86_64-userdebug royd_arm64-userdebug configured modern "system vendor system_ext product" memfd-capable
check_version 15 android-15.0.0_r36 royd_x86_64-bp1a-userdebug royd_arm64-bp1a-userdebug baseline modern "system vendor system_ext product" memfd-capable
check_version 16 android-16.0.0_r4 royd_x86_64-bp4a-userdebug royd_arm64-bp4a-userdebug configured modern "system vendor system_ext product" memfd-capable
check_version 17 android-17.0.0_r1 royd_x86_64-cp2a-userdebug royd_arm64-cp2a-userdebug configured modern "system vendor system_ext product" memfd-capable

expected=$(
  cat <<'EOF2'
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

if ROYD_ANDROID_VERSION=8 "$script_dir/lunch-target.sh" x86_64 >/dev/null 2>&1; then
  printf '%s\n' 'error: unsupported Android 8.0 version was accepted; royd starts at 8.1' >&2
  exit 1
fi

printf '%s\n' 'Android version matrix test passed'
