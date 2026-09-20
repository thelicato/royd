#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1091
. "$script_dir/common.sh"

backend=${1:-${ROYD_GRAPHICS_BACKEND:-software}}
arch=${2:-${ROYD_GRAPHICS_ARCH:-}}

case "$backend" in
  software)
    printf '%s\n' software
    ;;
  host-gpu-generic)
    [ "${ANDROID_HOST_GPU_SUPPORTED:-0}" = 1 ] || fail "host GPU backend is not configured for Android $ANDROID_VERSION"
    printf '%s\n' host-gpu-generic
    ;;
  host-gpu-intel)
    [ "${ANDROID_HOST_GPU_SUPPORTED:-0}" = 1 ] || fail "host GPU backend is not configured for Android $ANDROID_VERSION"
    if [ -n "$arch" ] && [ "$arch" != x86_64 ]; then
      fail "host-gpu-intel requires x86_64, got $arch"
    fi
    printf '%s\n' host-gpu-intel
    ;;
  *)
    fail "unsupported graphics backend: $backend; expected software, host-gpu-generic, or host-gpu-intel"
    ;;
esac
