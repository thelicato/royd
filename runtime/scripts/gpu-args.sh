#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
backend=${1:-${ROYD_GRAPHICS_BACKEND:-software}}
arch=${2:-${ROYD_GRAPHICS_ARCH:-x86_64}}
backend=$(ROYD_GRAPHICS_ARCH="$arch" "$repo_root/android/scripts/graphics-backend.sh" "$backend" "$arch")

case "$backend" in
  software)
    ;;
  host-gpu-*)
    printf '%s\n' '--device=/dev/dri:/dev/dri'
    ;;
esac
