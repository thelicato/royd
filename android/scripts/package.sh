#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1091
. "$script_dir/common.sh"

require_command mount
require_command mountpoint
require_command tar
require_command umount

src=$(source_dir)
arch=${1:-x86_64}
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

product_out="$src/out/target/product/$product"
system_img="$product_out/system.img"
vendor_img="$product_out/vendor.img"
runtime_dir="$repo_root/.work/runtime"
output="$runtime_dir/royd-$arch.tar"
tmp=$(mktemp -d)
system_mount="$tmp/system"
vendor_mount="$tmp/vendor"

cleanup() {
  mountpoint -q "$vendor_mount" 2>/dev/null && umount "$vendor_mount" || true
  mountpoint -q "$system_mount" 2>/dev/null && umount "$system_mount" || true
  rm -rf "$tmp"
}
trap cleanup EXIT INT TERM

[ -f "$system_img" ] || fail "system image not found at $system_img; build Android first"
[ -f "$vendor_img" ] || fail "vendor image not found at $vendor_img; build Android first"
mkdir -p "$runtime_dir" "$system_mount" "$vendor_mount"

printf 'Mounting Android images for %s\n' "$arch"
mount -o loop,ro "$system_img" "$system_mount"
mount -o loop,ro "$vendor_img" "$vendor_mount"

printf 'Creating OCI root filesystem archive at %s\n' "$output"
rm -f "$output"
tar --xattrs --numeric-owner -C "$system_mount" --exclude='./vendor' -cf "$output" .
tar --xattrs --numeric-owner --transform='s#^\./#./vendor/#' -C "$vendor_mount" -rf "$output" .
printf 'Runtime root filesystem is ready: %s\n' "$output"
