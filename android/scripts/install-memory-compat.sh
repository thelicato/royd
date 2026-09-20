#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1091
. "$script_dir/common.sh"

src=${1:-$(source_dir)}
compat_source="$android_dir/compat/memory/ashmem-dev.c"

case "$ANDROID_MEMORY_COMPAT" in
  libcutils-memfd-overlay)
    libcutils="$src/system/core/libcutils"
    [ -d "$libcutils" ] || fail "libcutils source directory not found at $libcutils"
    if [ -f "$libcutils/ashmem-dev.cpp" ]; then
      target="$libcutils/ashmem-dev.cpp"
    elif [ -f "$libcutils/ashmem-dev.c" ]; then
      target="$libcutils/ashmem-dev.c"
    else
      fail "legacy libcutils ashmem implementation not found"
    fi
    [ -f "$compat_source" ] || fail "royd memfd compatibility source not found: $compat_source"
    cp "$compat_source" "$target"
    printf 'Installed royd memfd-backed libcutils compatibility for Android %s: %s\n' "$ANDROID_VERSION" "$target"
    ;;
  native-memfd)
    printf 'Android %s uses its native memfd-capable userspace path\n' "$ANDROID_VERSION"
    ;;
  *)
    fail "unknown Android memory compatibility mode: $ANDROID_MEMORY_COMPAT"
    ;;
esac
