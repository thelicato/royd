#!/bin/sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1091
. "$script_dir/common.sh"
cat "$android_dir/build-contract.env"
case " $ANDROID_REQUIRED_PARTITIONS " in
  *' system_ext '*)
    printf '%s\n' 'BOARD_SYSTEM_EXTIMAGE_FILE_SYSTEM_TYPE=ext4' 'TARGET_COPY_OUT_SYSTEM_EXT=system_ext'
    ;;
esac
case " $ANDROID_REQUIRED_PARTITIONS " in
  *' product '*)
    printf '%s\n' 'BOARD_PRODUCTIMAGE_FILE_SYSTEM_TYPE=ext4' 'TARGET_COPY_OUT_PRODUCT=product'
    ;;
esac
case "$ANDROID_PRODUCT_FAMILY" in
  modern)
    printf '%s\n' 'PRODUCT_OTA_ENFORCE_VINTF_KERNEL_REQUIREMENTS=false'
    ;;
esac
