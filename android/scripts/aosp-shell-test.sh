#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
android_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM
mkdir -p "$tmp/repo" "$tmp/src/build"
cp -a "$android_dir" "$tmp/repo/android"

for script in config-check.sh build.sh; do
  target="$tmp/repo/android/scripts/$script"
  [ "$(head -n 1 "$target")" = '#!/usr/bin/env bash' ] || {
    printf 'error: %s must run under Bash for AOSP envsetup\n' "$script" >&2
    exit 1
  }
  grep -A1 -F '. "$script_dir/common.sh"' "$target" | grep -Fq 'set +u' || {
    printf 'error: %s must disable nounset after sourcing common.sh\n' "$script" >&2
    exit 1
  }
done

cat > "$tmp/src/build/envsetup.sh" <<'MOCK'
function royd_envsetup_shell_probe {
  : "$ROYD_AOSP_OPTIONAL_UNSET"
}
royd_envsetup_shell_probe

function lunch {
  case "$1" in
    royd_x86_64-bp1a-userdebug)
      MOCK_PRODUCT=royd_x86_64
      MOCK_ARCH=x86_64
      ;;
    royd_arm64-bp1a-userdebug)
      MOCK_PRODUCT=royd_arm64
      MOCK_ARCH=arm64
      ;;
    *)
      return 1
      ;;
  esac
}

function get_build_var {
  case "$1" in
    TARGET_PRODUCT|TARGET_DEVICE) printf '%s\n' "$MOCK_PRODUCT" ;;
    TARGET_ARCH) printf '%s\n' "$MOCK_ARCH" ;;
    TARGET_NO_BOOTLOADER|TARGET_NO_KERNEL) printf '%s\n' true ;;
    PRODUCT_OTA_ENFORCE_VINTF_KERNEL_REQUIREMENTS) printf '%s\n' false ;;
    BOARD_SYSTEMIMAGE_FILE_SYSTEM_TYPE|BOARD_VENDORIMAGE_FILE_SYSTEM_TYPE|BOARD_SYSTEM_EXTIMAGE_FILE_SYSTEM_TYPE|BOARD_PRODUCTIMAGE_FILE_SYSTEM_TYPE) printf '%s\n' ext4 ;;
    TARGET_COPY_OUT_VENDOR) printf '%s\n' vendor ;;
    TARGET_COPY_OUT_SYSTEM_EXT) printf '%s\n' system_ext ;;
    TARGET_COPY_OUT_PRODUCT) printf '%s\n' product ;;
    *) return 1 ;;
  esac
}

function m {
  printf '%s\n' "$*" >> "$ROYD_M_LOG"
}
MOCK

: > "$tmp/m.log"
ROYD_ANDROID_VERSION=15 \
ROYD_ANDROID_SRC="$tmp/src" \
ROYD_M_LOG="$tmp/m.log" \
  "$tmp/repo/android/scripts/config-check.sh" x86_64 >/dev/null

ROYD_ANDROID_VERSION=15 \
ROYD_ANDROID_SRC="$tmp/src" \
ROYD_M_LOG="$tmp/m.log" \
JOBS=3 \
  "$tmp/repo/android/scripts/build.sh" x86_64 standard >/dev/null

grep -Fqx -- '-j3' "$tmp/m.log" || {
  printf '%s\n' 'error: mock AOSP build command was not reached under the Bash envsetup contract' >&2
  exit 1
}

printf '%s\n' 'Android AOSP Bash and nounset contract test passed'
