#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

[ "$(ROYD_ANDROID_VERSION=8.0 "$script_dir/graphics-backend.sh" software x86_64)" = software ]
[ "$(ROYD_ANDROID_VERSION=15 "$script_dir/graphics-backend.sh" host-gpu-generic x86_64)" = host-gpu-generic ]
[ "$(ROYD_ANDROID_VERSION=15 "$script_dir/graphics-backend.sh" host-gpu-intel x86_64)" = host-gpu-intel ]

if ROYD_ANDROID_VERSION=9 "$script_dir/graphics-backend.sh" host-gpu-generic x86_64 >/dev/null 2>&1; then
  printf '%s\n' 'error: Android 9 unexpectedly accepted host GPU graphics' >&2
  exit 1
fi
if ROYD_ANDROID_VERSION=15 "$script_dir/graphics-backend.sh" host-gpu-intel arm64 >/dev/null 2>&1; then
  printf '%s\n' 'error: arm64 unexpectedly accepted the Intel graphics backend' >&2
  exit 1
fi

grep -Fq 'gralloc.royd' "$script_dir/../graphics/software.mk"
grep -Fq 'libGLES_mesa' "$script_dir/../graphics/host-gpu-generic.mk"
grep -Fq 'gralloc.minigbm_intel' "$script_dir/../graphics/host-gpu-intel.mk"
printf '%s\n' 'Android graphics backend test passed'
