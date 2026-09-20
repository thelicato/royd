#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1091
. "$script_dir/common.sh"

arch=${1:-x86_64}
case "$arch" in
  x86_64) product=$ANDROID_PRODUCT_X86_64 ;;
  arm64) product=$ANDROID_PRODUCT_ARM64 ;;
  *) fail "unsupported architecture: $arch; expected x86_64 or arm64" ;;
esac

case "$ANDROID_LUNCH_STYLE" in
  legacy)
    printf '%s-%s\n' "$product" "$ANDROID_VARIANT"
    ;;
  release)
    [ -n "$ANDROID_RELEASE" ] || fail "Android $ANDROID_VERSION requires ANDROID_RELEASE"
    printf '%s-%s-%s\n' "$product" "$ANDROID_RELEASE" "$ANDROID_VARIANT"
    ;;
  *)
    fail "unsupported lunch style for Android $ANDROID_VERSION: $ANDROID_LUNCH_STYLE"
    ;;
esac
