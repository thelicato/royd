#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1091
. "$script_dir/common.sh"
# shellcheck disable=SC1091
. "$repo_root/runtime/image.env"

require_command cpio
require_command file
require_command gzip
require_command lz4
require_command mount
require_command mountpoint
require_command sha256sum
require_command sudo
require_command tar
require_command umount

src=$(source_dir)
arch=${1:-x86_64}
profile=${2:-${ROYD_ANDROID_PROFILE:-standard}}
profile=$($script_dir/profile.sh "$profile")
hal_profile=${ROYD_HAL_PROFILE:-graphical}
hal_profile=$("$script_dir/hal-profile.sh" "$hal_profile")
graphics_backend=${ROYD_GRAPHICS_BACKEND:-software}
graphics_backend=$(ROYD_GRAPHICS_ARCH="$arch" "$script_dir/graphics-backend.sh" "$graphics_backend" "$arch")
profile_policy=$(ROYD_ANDROID_VERSION="$ANDROID_VERSION" "$script_dir/profile-policy.sh" "$profile")
profile_policy_sha256=$(ROYD_ANDROID_VERSION="$ANDROID_VERSION" "$script_dir/profile-packages.sh" "$profile" | sha256sum | awk '{print $1}')
graphics_suffix=
[ "$graphics_backend" = software ] || graphics_suffix="-$graphics_backend"
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
runtime_dir="$repo_root/.work/runtime/android-$ANDROID_VERSION"
output="$runtime_dir/royd-$arch-$profile-$hal_profile$graphics_suffix.tar"
manifest="$runtime_dir/royd-$arch-$profile-$hal_profile$graphics_suffix.manifest"
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
printf 'Extracting Android ramdisk for %s image profile %s, HAL profile %s and graphics backend %s\n' "$arch" "$profile" "$hal_profile" "$graphics_backend"
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
printf 'Creating OCI root filesystem archive for %s image profile %s, HAL profile %s and graphics backend %s\n' "$arch" "$profile" "$hal_profile" "$graphics_backend"
sudo tar --xattrs --numeric-owner -C "$root_dir" -cf - . > "$output"
for partition in $ANDROID_REQUIRED_PARTITIONS; do
  append_image "$partition" "$partition" yes
done
for partition in ${ANDROID_OPTIONAL_PARTITIONS:-}; do
  append_image "$partition" "$partition" no
done

entry_dir="$tmp/entrypoint"
mkdir -p "$entry_dir"
cp "$repo_root/runtime/rootfs/royd-entrypoint" "$entry_dir/royd-entrypoint"
chmod 0755 "$entry_dir/royd-entrypoint"
touch -t 197001010000 "$entry_dir/royd-entrypoint"
sudo tar --numeric-owner --owner=0 --group=0 -C "$entry_dir" -rf "$output" ./royd-entrypoint

release_dir="$tmp/release"
mkdir -p "$release_dir"
cat > "$release_dir/royd-release" <<EOF
ROYD_IMAGE_FORMAT=$ROYD_IMAGE_FORMAT
ROYD_ANDROID_VERSION=$ANDROID_VERSION
ROYD_AOSP_TAG=$AOSP_TAG
ROYD_ARCH=$arch
ROYD_IMAGE_PROFILE=$profile
ROYD_PROFILE_POLICY=$profile_policy
ROYD_PROFILE_POLICY_SHA256=$profile_policy_sha256
ROYD_HAL_PROFILE=$hal_profile
ROYD_GRAPHICS_BACKEND=$graphics_backend
ANDROID_PRODUCT=$product
ANDROID_REQUIRED_PARTITIONS=$ANDROID_REQUIRED_PARTITIONS
ANDROID_MEMORY_COMPAT=$ANDROID_MEMORY_COMPAT
ROYD_RUNTIME_ENTRYPOINT=/royd-entrypoint
ROYD_RUNTIME_CONFIG=/royd-runtime.conf
EOF
touch -t 197001010000 "$release_dir/royd-release"
sudo tar --numeric-owner --owner=0 --group=0 -C "$release_dir" -rf "$output" ./royd-release

archive_sha256=$(sha256sum "$output" | awk '{print $1}')
cat > "$manifest" <<EOF
ROYD_IMAGE_FORMAT=$ROYD_IMAGE_FORMAT
ROYD_ANDROID_VERSION=$ANDROID_VERSION
ROYD_AOSP_TAG=$AOSP_TAG
ROYD_ARCH=$arch
ROYD_IMAGE_PROFILE=$profile
ROYD_PROFILE_POLICY=$profile_policy
ROYD_PROFILE_POLICY_SHA256=$profile_policy_sha256
ROYD_HAL_PROFILE=$hal_profile
ROYD_GRAPHICS_BACKEND=$graphics_backend
ANDROID_PRODUCT=$product
ANDROID_REQUIRED_PARTITIONS=$ANDROID_REQUIRED_PARTITIONS
ANDROID_MEMORY_COMPAT=$ANDROID_MEMORY_COMPAT
ROYD_RUNTIME_ENTRYPOINT=/royd-entrypoint
ROYD_RUNTIME_CONFIG=/royd-runtime.conf
ARCHIVE_SHA256=$archive_sha256
EOF
printf 'Runtime manifest is ready: %s\n' "$manifest"
printf 'Runtime root filesystem is ready: %s\n' "$output"
