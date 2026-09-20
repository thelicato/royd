#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1091
. "$script_dir/common.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM
mkdir -p "$tmp/build" "$tmp/system/core/libcutils"
printf '%s\n' 'mock ashmem backend' > "$tmp/system/core/libcutils/ashmem-dev.c"

cat > "$tmp/build/envsetup.sh" <<'MOCK'
lunch() {
  case "$1" in
    royd_x86_64-bp1a-userdebug|royd_x86_64-bp4a-userdebug|royd_x86_64-cp2a-userdebug|royd_x86_64-userdebug)
      MOCK_PRODUCT=royd_x86_64
      MOCK_ARCH=x86_64
      ;;
    royd_arm64-bp1a-userdebug|royd_arm64-bp4a-userdebug|royd_arm64-cp2a-userdebug|royd_arm64-userdebug)
      MOCK_PRODUCT=royd_arm64
      MOCK_ARCH=arm64
      ;;
    *)
      return 1
      ;;
  esac
}

get_build_var() {
  case "$1" in
    TARGET_PRODUCT|TARGET_DEVICE) printf '%s\n' "$MOCK_PRODUCT" ;;
    TARGET_ARCH) printf '%s\n' "$MOCK_ARCH" ;;
    TARGET_NO_BOOTLOADER|TARGET_NO_KERNEL) printf '%s\n' true ;;
    BOARD_SYSTEMIMAGE_FILE_SYSTEM_TYPE|BOARD_VENDORIMAGE_FILE_SYSTEM_TYPE|BOARD_SYSTEM_EXTIMAGE_FILE_SYSTEM_TYPE|BOARD_PRODUCTIMAGE_FILE_SYSTEM_TYPE) printf '%s\n' ext4 ;;
    TARGET_COPY_OUT_VENDOR) printf '%s\n' vendor ;;
    TARGET_COPY_OUT_SYSTEM_EXT) printf '%s\n' system_ext ;;
    TARGET_COPY_OUT_PRODUCT) printf '%s\n' product ;;
    *) return 1 ;;
  esac
}
MOCK

for version in 8.0 8.1 9 10 11 12 13 14 15 16 17; do
  output=$(ROYD_ANDROID_VERSION="$version" ROYD_ANDROID_SRC="$tmp" "$script_dir/config-check.sh")
  printf '%s\n' "$output" | grep -Fq 'Android build contract checks passed'
done

# Prove that a resolved AOSP value which violates the contract is rejected.
python3 - "$tmp/build/envsetup.sh" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text().replace('TARGET_COPY_OUT_PRODUCT) printf \'%s\\n\' product ;;', 'TARGET_COPY_OUT_PRODUCT) printf \'%s\\n\' system/product ;;')
p.write_text(s)
PY
if ROYD_ANDROID_VERSION=15 ROYD_ANDROID_SRC="$tmp" "$script_dir/config-check.sh" >/dev/null 2>&1; then
  printf '%s\n' 'error: config check accepted a broken product copy-out path' >&2
  exit 1
fi

printf '%s\n' 'Android resolved build contract test passed for versions 8.0 through 17'
