#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1091
. "$script_dir/common.sh"

require_command cpio
require_command file
require_command gzip
require_command lz4
require_command mount
require_command mountpoint
require_command sudo
require_command tar
require_command umount

src=$(source_dir)
arch=${1:-x86_64}
profile=${2:-${ROYD_ANDROID_PROFILE:-standard}}
profile=$($script_dir/profile.sh "$profile")
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
host_bin="$src/out/host/linux-x86/bin"
runtime_dir="$repo_root/.work/runtime"
output="$runtime_dir/royd-$arch-$profile.tar"
tmp=$(mktemp -d)
mounts=

cleanup() {
  for mount_dir in $mounts; do
    mountpoint -q "$mount_dir" 2>/dev/null && sudo umount "$mount_dir" || true
  done
  rm -rf "$tmp"
}
trap cleanup EXIT INT TERM

prepare_image() {
  image=$1
  raw=$2
  magic=$(od -An -tx4 -N4 "$image" 2>/dev/null | tr -d ' ')
  if [ "$magic" = ed26ff3a ]; then
    simg2img="$host_bin/simg2img"
    [ -x "$simg2img" ] || fail "simg2img not found at $simg2img"
    "$simg2img" "$image" "$raw"
    printf '%s\n' "$raw"
  else
    printf '%s\n' "$image"
  fi
}

append_image() {
  name=$1
  destination=$2
  required=$3
  image="$product_out/$name.img"
  if [ ! -f "$image" ]; then
    [ "$required" = yes ] && fail "$name image not found at $image; build Android first"
    return
  fi

  mount_dir="$tmp/mnt-$name"
  raw="$tmp/$name.raw.img"
  mkdir -p "$mount_dir"
  prepared=$(prepare_image "$image" "$raw")
  sudo mount -o loop,ro "$prepared" "$mount_dir"
  mounts="$mount_dir $mounts"

  if [ -z "$destination" ]; then
    sudo tar --xattrs --numeric-owner -C "$mount_dir" -cf "$output" .
  else
    sudo tar --xattrs --numeric-owner --transform="s#^\./#./$destination/#" -C "$mount_dir" -rf "$output" .
  fi
  sudo umount "$mount_dir"
}

ramdisk_img="$product_out/ramdisk.img"
root_dir="$tmp/root"
[ -f "$ramdisk_img" ] || fail "Android ramdisk not found at $ramdisk_img; build Android first"
mkdir -p "$runtime_dir" "$root_dir"
rm -f "$output"
printf 'Extracting Android ramdisk for %s profile %s\n' "$arch" "$profile"
case $(file -b "$ramdisk_img") in
  *gzip*)
    gzip -dc "$ramdisk_img" | (cd "$root_dir" && sudo cpio -idmu --quiet)
    ;;
  *LZ4*|*lz4*)
    lz4 -dc "$ramdisk_img" | (cd "$root_dir" && sudo cpio -idmu --quiet)
    ;;
  *)
    fail "unsupported ramdisk compression: $(file -b "$ramdisk_img")"
    ;;
esac
printf 'Creating OCI root filesystem archive for %s profile %s\n' "$arch" "$profile"
sudo tar --xattrs --numeric-owner -C "$root_dir" -cf - . > "$output"
append_image system system yes
append_image vendor vendor yes
append_image system_ext system_ext yes
append_image product product yes
append_image odm odm no
printf 'Runtime root filesystem is ready: %s\n' "$output"
