#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1091
. "$script_dir/common.sh"

src=$(source_dir)
arch=${1:-x86_64}
jobs=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '4')}

[ -d "$src/build" ] || fail "Android source tree not found at $src; run android/scripts/sync.sh first"

case "$arch" in
  x86_64)
    product=$ANDROID_PRODUCT_X86_64
    ;;
  arm64)
    product=$ANDROID_PRODUCT_ARM64
    ;;
  *)
    fail "unsupported architecture: $arch; expected x86_64 or arm64"
    ;;
esac

lunch_target="${product}-${ANDROID_RELEASE}-${ANDROID_VARIANT}"
printf 'Building %s with %s jobs\n' "$lunch_target" "$jobs"

(
  cd "$src"
  # build/envsetup.sh is intentionally sourced in the same shell as lunch and m.
  # shellcheck disable=SC1091
  . build/envsetup.sh
  lunch "$lunch_target"
  m -j"$jobs"
)
