#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1091
. "$script_dir/common.sh"

src=$(source_dir)
profile=${ROYD_ANDROID_PROFILE:-standard}
profile=$($script_dir/profile.sh "$profile")
[ -d "$src/build" ] || fail "Android source tree not found at $src; run android/scripts/sync.sh first"
"$script_dir/install-royd.sh" "$src" "$profile"

check_product() {
  arch=$1
  case "$arch" in
    x86_64)
      product=$ANDROID_PRODUCT_X86_64
      expected_arch=x86_64
      ;;
    arm64)
      product=$ANDROID_PRODUCT_ARM64
      expected_arch=arm64
      ;;
    *)
      fail "unsupported architecture: $arch"
      ;;
  esac

  lunch_target=$("$script_dir/lunch-target.sh" "$arch")
  printf 'Checking resolved AOSP configuration for %s\n' "$lunch_target"

  (
    cd "$src"
    # shellcheck disable=SC1091
    . build/envsetup.sh >/dev/null
    lunch "$lunch_target" >/dev/null

    actual_product=$(get_build_var TARGET_PRODUCT)
    actual_device=$(get_build_var TARGET_DEVICE)
    actual_arch=$(get_build_var TARGET_ARCH)

    [ "$actual_product" = "$product" ] || {
      printf 'error: TARGET_PRODUCT=%s, expected %s\n' "$actual_product" "$product" >&2
      exit 1
    }
    [ "$actual_device" = "$product" ] || {
      printf 'error: TARGET_DEVICE=%s, expected %s\n' "$actual_device" "$product" >&2
      exit 1
    }
    [ "$actual_arch" = "$expected_arch" ] || {
      printf 'error: TARGET_ARCH=%s, expected %s\n' "$actual_arch" "$expected_arch" >&2
      exit 1
    }

    while IFS='=' read -r name expected; do
      case "$name" in
        ''|'#'*) continue ;;
      esac
      actual=$(get_build_var "$name")
      [ "$actual" = "$expected" ] || {
        printf 'error: %s=%s, expected %s for %s\n' "$name" "$actual" "$expected" "$lunch_target" >&2
        exit 1
      }
      printf '  %s=%s\n' "$name" "$actual"
    done <<EOF_CONTRACT
$("$script_dir/contract-lines.sh")
EOF_CONTRACT

    printf '  TARGET_PRODUCT=%s\n' "$actual_product"
    printf '  TARGET_DEVICE=%s\n' "$actual_device"
    printf '  TARGET_ARCH=%s\n' "$actual_arch"
  )
}

if [ "$#" -eq 0 ]; then
  check_product x86_64
  check_product arm64
else
  for arch in "$@"; do
    check_product "$arch"
  done
fi

printf '%s\n' 'Android build contract checks passed'
