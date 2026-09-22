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

src="$tmp/aosp"
product_out="$src/out/target/product/royd_x86_64"
mkdir -p "$product_out" "$src/out/host/linux-x86/bin"
ramdisk_root="$tmp/ramdisk-root"
mkdir -p "$ramdisk_root"
(
  cd "$ramdisk_root"
  printf '.\n' | cpio -o -H newc --quiet
) | gzip > "$product_out/ramdisk.img"
for partition in system vendor system_ext product; do
  printf '%s\n' raw > "$product_out/$partition.img"
done

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
  printf '%s\n' 'simulated permission denial removing privileged ramdisk extraction' >&2
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
exit 0
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
package_tmp="$tmp/package-tmp"
stdout="$tmp/package.stdout"
stderr="$tmp/package.stderr"
if ! PATH="$mock_bin:$PATH" \
  REAL_RM="$real_rm" \
  PACKAGE_TMP="$package_tmp" \
  ROYD_ANDROID_VERSION=15 \
  ROYD_ANDROID_SRC="$src" \
    "$test_repo/android/scripts/package.sh" x86_64 standard >"$stdout" 2>"$stderr"; then
  cat "$stdout" >&2
  cat "$stderr" >&2
  printf '%s\n' 'error: package cleanup regression did not complete successfully' >&2
  exit 1
fi

runtime_dir="$test_repo/.work/runtime/android-15"
archive="$runtime_dir/royd-x86_64-standard-graphical.tar"
manifest="$runtime_dir/royd-x86_64-standard-graphical.manifest"
[ -f "$archive" ] || {
  printf '%s\n' 'error: package cleanup regression did not produce the runtime archive' >&2
  exit 1
}
[ -f "$manifest" ] || {
  printf '%s\n' 'error: package cleanup regression did not produce the runtime manifest' >&2
  exit 1
}
grep -Fq 'Runtime root filesystem is ready:' "$stdout" || {
  printf '%s\n' 'error: package cleanup regression did not reach successful packaging' >&2
  exit 1
}
if grep -Fq 'simulated permission denial' "$stderr"; then
  printf '%s\n' 'error: best-effort package cleanup leaked the simulated deletion error' >&2
  exit 1
fi
if tar -tf "$archive" | grep -q '^./odm/'; then
  printf '%s\n' 'error: absent optional odm partition was unexpectedly packaged' >&2
  exit 1
fi

rm -f "$product_out/vendor.img"
required_stdout="$tmp/required.stdout"
required_stderr="$tmp/required.stderr"
if PATH="$mock_bin:$PATH" \
  REAL_RM="$real_rm" \
  PACKAGE_TMP="$package_tmp" \
  ROYD_ANDROID_VERSION=15 \
  ROYD_ANDROID_SRC="$src" \
    "$test_repo/android/scripts/package.sh" x86_64 standard >"$required_stdout" 2>"$required_stderr"; then
  printf '%s\n' 'error: package contract accepted a missing required vendor image' >&2
  exit 1
fi
grep -Fq "error: vendor image not found at $product_out/vendor.img; build Android first" "$required_stderr" || {
  cat "$required_stderr" >&2
  printf '%s\n' 'error: missing required partition did not report the expected failure' >&2
  exit 1
}

printf '%s\n' 'Android package contract test passed'
