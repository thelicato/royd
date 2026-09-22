#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

test_repo="$tmp/repo"
mkdir -p "$test_repo"
cp -R "$repo_root/android" "$test_repo/android"
mkdir -p "$test_repo/runtime"
cp "$repo_root/runtime/image.env" "$test_repo/runtime/image.env"
mkdir -p "$test_repo/runtime/rootfs"
cp "$repo_root/runtime/rootfs/royd-entrypoint" "$test_repo/runtime/rootfs/royd-entrypoint"

mock_bin="$tmp/bin"
mkdir -p "$mock_bin"
cat > "$mock_bin/mktemp" <<'MOCK'
#!/bin/sh
set -eu
[ "${1:-}" = -d ] || exit 2
mkdir -p "$PACKAGE_TMP"
printf '%s\n' "$PACKAGE_TMP"
MOCK
cat > "$mock_bin/rm" <<'MOCK'
#!/bin/sh
set -eu
if [ "$#" -eq 2 ] && [ "$1" = -rf ] && [ "$2" = "$PACKAGE_TMP" ]; then
  printf '%s\n' 'simulated permission denial removing privileged package extraction' >&2
  exit 1
fi
exec "$REAL_RM" "$@"
MOCK
cat > "$mock_bin/sudo" <<'MOCK'
#!/bin/sh
exec "$@"
MOCK
cat > "$mock_bin/mount" <<'MOCK'
#!/bin/sh
set -eu
[ "$#" -eq 4 ] && [ "$1" = -o ] && [ "$2" = loop,ro ] || exit 2
image=$3
mount_dir=$4
name=$(basename "$image")
case "${ROYD_ANDROID_VERSION:-}:$name" in
  15:system.img)
    mkdir -p "$mount_dir/system/bin" "$mount_dir/dev" "$mount_dir/proc" "$mount_dir/sys"
    printf '%s\n' modern-system-shell > "$mount_dir/system/bin/sh"
    printf '%s\n' modern-system-init > "$mount_dir/system/bin/init"
    ln -s /system/bin "$mount_dir/bin"
    ln -s /system/bin/init "$mount_dir/init"
    ;;
  15:vendor.img)
    mkdir -p "$mount_dir/bin"
    printf '%s\n' vendor-marker > "$mount_dir/bin/vendor-marker"
    ;;
  15:system_ext.img)
    mkdir -p "$mount_dir/etc"
    printf '%s\n' system-ext-marker > "$mount_dir/etc/system-ext-marker"
    ;;
  15:product.img)
    mkdir -p "$mount_dir/etc"
    printf '%s\n' product-marker > "$mount_dir/etc/product-marker"
    ;;
  9:system.img)
    mkdir -p "$mount_dir/bin"
    printf '%s\n' legacy-system-shell > "$mount_dir/bin/sh"
    ;;
  9:vendor.img)
    mkdir -p "$mount_dir/bin"
    printf '%s\n' legacy-vendor-marker > "$mount_dir/bin/vendor-marker"
    ;;
  *)
    printf 'unexpected mock mount: Android %s image %s\n' "${ROYD_ANDROID_VERSION:-unset}" "$name" >&2
    exit 1
    ;;
esac
MOCK
cat > "$mock_bin/umount" <<'MOCK'
#!/bin/sh
exit 0
MOCK
cat > "$mock_bin/mountpoint" <<'MOCK'
#!/bin/sh
exit 1
MOCK
cat > "$mock_bin/lz4" <<'MOCK'
#!/bin/sh
exit 1
MOCK
chmod 0755 "$mock_bin"/*

real_rm=$(command -v rm)

src15="$tmp/aosp15"
product15="$src15/out/target/product/royd_x86_64"
mkdir -p "$product15" "$src15/out/host/linux-x86/bin"
for partition in system vendor system_ext product; do
  printf '%s\n' raw > "$product15/$partition.img"
done
modern_stdout="$tmp/modern.stdout"
modern_stderr="$tmp/modern.stderr"
if ! PATH="$mock_bin:$PATH" \
  REAL_RM="$real_rm" \
  PACKAGE_TMP="$tmp/package-modern" \
  ROYD_ANDROID_VERSION=15 \
  ROYD_ANDROID_SRC="$src15" \
    "$test_repo/android/scripts/package.sh" x86_64 standard >"$modern_stdout" 2>"$modern_stderr"; then
  cat "$modern_stdout" >&2
  cat "$modern_stderr" >&2
  printf '%s\n' 'error: modern system-root package contract did not complete successfully' >&2
  exit 1
fi

runtime15="$test_repo/.work/runtime/android-15"
archive15="$runtime15/royd-x86_64-standard-graphical.tar"
manifest15="$runtime15/royd-x86_64-standard-graphical.manifest"
[ -f "$archive15" ] || {
  printf '%s\n' 'error: modern package contract did not produce the runtime archive' >&2
  exit 1
}
[ -f "$manifest15" ] || {
  printf '%s\n' 'error: modern package contract did not produce the runtime manifest' >&2
  exit 1
}
grep -Fq 'Creating OCI root filesystem archive from Android system image' "$modern_stdout" || {
  printf '%s\n' 'error: modern package contract did not select system.img as the OCI root' >&2
  exit 1
}
if grep -Fq 'Extracting Android ramdisk' "$modern_stdout"; then
  printf '%s\n' 'error: modern package contract unexpectedly extracted ramdisk.img' >&2
  exit 1
fi
if grep -Fq 'simulated permission denial' "$modern_stderr"; then
  printf '%s\n' 'error: best-effort package cleanup leaked the simulated deletion error' >&2
  exit 1
fi

modern_root="$tmp/modern-root"
mkdir -p "$modern_root"
tar -xf "$archive15" -C "$modern_root"
[ "$(readlink "$modern_root/bin")" = /system/bin ] || {
  printf '%s\n' 'error: modern packaged /bin symlink does not target /system/bin' >&2
  exit 1
}
[ "$(readlink "$modern_root/init")" = /system/bin/init ] || {
  printf '%s\n' 'error: modern packaged /init symlink does not target /system/bin/init' >&2
  exit 1
}
[ -f "$modern_root/system/bin/sh" ] && [ ! -L "$modern_root/system/bin" ] || {
  printf '%s\n' 'error: modern packaged /system/bin is not the real directory from system.img' >&2
  exit 1
}
[ ! -e "$modern_root/system/system/bin/sh" ] || {
  printf '%s\n' 'error: modern system.img was nested under /system instead of used as OCI root' >&2
  exit 1
}
[ -f "$modern_root/vendor/bin/vendor-marker" ] || {
  printf '%s\n' 'error: vendor image was not merged at /vendor' >&2
  exit 1
}
[ -f "$modern_root/system_ext/etc/system-ext-marker" ] || {
  printf '%s\n' 'error: system_ext image was not merged at /system_ext' >&2
  exit 1
}
[ -f "$modern_root/product/etc/product-marker" ] || {
  printf '%s\n' 'error: product image was not merged at /product' >&2
  exit 1
}
[ ! -e "$modern_root/odm" ] || {
  printf '%s\n' 'error: absent optional odm partition was unexpectedly packaged' >&2
  exit 1
}

rm -f "$product15/vendor.img"
required_stdout="$tmp/required.stdout"
required_stderr="$tmp/required.stderr"
if PATH="$mock_bin:$PATH" \
  REAL_RM="$real_rm" \
  PACKAGE_TMP="$tmp/package-required" \
  ROYD_ANDROID_VERSION=15 \
  ROYD_ANDROID_SRC="$src15" \
    "$test_repo/android/scripts/package.sh" x86_64 standard >"$required_stdout" 2>"$required_stderr"; then
  printf '%s\n' 'error: package contract accepted a missing required vendor image' >&2
  exit 1
fi
grep -Fq "error: vendor image not found at $product15/vendor.img; build Android first" "$required_stderr" || {
  cat "$required_stderr" >&2
  printf '%s\n' 'error: missing required partition did not report the expected failure' >&2
  exit 1
}

src9="$tmp/aosp9"
product9="$src9/out/target/product/royd_x86_64"
mkdir -p "$product9" "$src9/out/host/linux-x86/bin"
ramdisk_root="$tmp/ramdisk-root"
mkdir -p "$ramdisk_root"
printf '%s\n' legacy-ramdisk-init > "$ramdisk_root/init"
(
  cd "$ramdisk_root"
  find . -print | cpio -o -H newc --quiet
) | gzip > "$product9/ramdisk.img"
printf '%s\n' raw > "$product9/system.img"
printf '%s\n' raw > "$product9/vendor.img"
legacy_stdout="$tmp/legacy.stdout"
legacy_stderr="$tmp/legacy.stderr"
if ! PATH="$mock_bin:$PATH" \
  REAL_RM="$real_rm" \
  PACKAGE_TMP="$tmp/package-legacy" \
  ROYD_ANDROID_VERSION=9 \
  ROYD_ANDROID_SRC="$src9" \
    "$test_repo/android/scripts/package.sh" x86_64 standard >"$legacy_stdout" 2>"$legacy_stderr"; then
  cat "$legacy_stdout" >&2
  cat "$legacy_stderr" >&2
  printf '%s\n' 'error: legacy ramdisk-root package contract did not complete successfully' >&2
  exit 1
fi
grep -Fq 'Extracting Android ramdisk' "$legacy_stdout" || {
  printf '%s\n' 'error: legacy package contract did not retain ramdisk-root assembly' >&2
  exit 1
}
if grep -Fq 'simulated permission denial' "$legacy_stderr"; then
  printf '%s\n' 'error: legacy best-effort cleanup leaked the simulated deletion error' >&2
  exit 1
fi
archive9="$test_repo/.work/runtime/android-9/royd-x86_64-standard-graphical.tar"
legacy_root="$tmp/legacy-root"
mkdir -p "$legacy_root"
tar -xf "$archive9" -C "$legacy_root"
grep -Fqx legacy-ramdisk-init "$legacy_root/init" || {
  printf '%s\n' 'error: legacy package contract did not keep ramdisk content at OCI root' >&2
  exit 1
}
grep -Fqx legacy-system-shell "$legacy_root/system/bin/sh" || {
  printf '%s\n' 'error: legacy system image was not merged at /system' >&2
  exit 1
}

printf '%s\n' 'Android package contract test passed'
