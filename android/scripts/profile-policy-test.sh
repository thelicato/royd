#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

expect_contains() {
  version=$1
  package=$2
  ROYD_ANDROID_VERSION="$version" "$script_dir/profile-packages.sh" minimal | grep -Fxq "$package" || {
    printf 'error: Android %s minimal policy does not remove %s\n' "$version" "$package" >&2
    exit 1
  }
}

expect_absent() {
  version=$1
  package=$2
  if ROYD_ANDROID_VERSION="$version" "$script_dir/profile-packages.sh" minimal | grep -Fxq "$package"; then
    printf 'error: Android %s minimal policy unexpectedly removes %s\n' "$version" "$package" >&2
    exit 1
  fi
}

[ -z "$(ROYD_ANDROID_VERSION=15 "$script_dir/profile-packages.sh" standard)" ]
[ "$(ROYD_ANDROID_VERSION=8.0 "$script_dir/profile-policy.sh" minimal)" = minimal-v2-legacy ]
[ "$(ROYD_ANDROID_VERSION=10 "$script_dir/profile-policy.sh" minimal)" = minimal-v2-transitional ]
[ "$(ROYD_ANDROID_VERSION=15 "$script_dir/profile-policy.sh" minimal)" = minimal-v2-modern ]
[ "$(ROYD_ANDROID_VERSION=15 "$script_dir/profile-policy.sh" standard)" = standard-v1 ]

expect_contains 8.0 Calendar
expect_contains 8.0 PrintSpooler
expect_absent 8.0 Camera2
expect_contains 10 Camera2
expect_contains 10 Email
expect_contains 15 Camera2
expect_contains 15 PhotoTable
expect_absent 15 Settings
expect_absent 15 SystemUI
expect_absent 15 PackageInstaller

for version in 8.0 8.1 9 10 11 12 13 14 15 16 17; do
  packages=$(ROYD_ANDROID_VERSION="$version" "$script_dir/profile-packages.sh" minimal)
  [ -n "$packages" ] || {
    printf 'error: Android %s minimal package policy is empty\n' "$version" >&2
    exit 1
  }
  [ "$(printf '%s\n' "$packages" | LC_ALL=C sort -u)" = "$packages" ] || {
    printf 'error: Android %s minimal package policy is not sorted and unique\n' "$version" >&2
    exit 1
  }
done

printf '%s\n' 'Android image profile policy checks passed'
