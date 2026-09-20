#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)

[ -z "$(ROYD_ANDROID_VERSION=15 "$script_dir/gpu-args.sh" software x86_64)" ]
[ "$(ROYD_ANDROID_VERSION=15 "$script_dir/gpu-args.sh" host-gpu-generic x86_64)" = '--device=/dev/dri:/dev/dri' ]
[ "$(ROYD_ANDROID_VERSION=15 "$script_dir/gpu-args.sh" host-gpu-intel x86_64)" = '--device=/dev/dri:/dev/dri' ]
if ROYD_ANDROID_VERSION=9 "$script_dir/gpu-args.sh" host-gpu-generic x86_64 >/dev/null 2>&1; then
  printf '%s\n' 'error: Android 9 unexpectedly accepted host GPU runtime arguments' >&2
  exit 1
fi

grep -Fq '/dev/dri:/dev/dri' "$repo_root/runtime/compose.gpu.yaml"
grep -Fq 'ro.hardware.egl=mesa' "$repo_root/android/graphics/host-gpu-generic.mk"
grep -Fq 'gralloc.minigbm' "$repo_root/android/graphics/host-gpu-generic.mk"
grep -Fq 'gralloc.minigbm_intel' "$repo_root/android/graphics/host-gpu-intel.mk"
grep -Fq 'ro.hardware.egl=swiftshader' "$repo_root/android/graphics/software.mk"
grep -Fq 'renderD*' "$repo_root/runtime/scripts/host-check.sh"
grep -Fq 'renderD*' "$repo_root/android/royd/vendor/royd/bin/royd-hardware-setup"
if grep -Fq 'renderD128' "$repo_root/runtime/scripts/host-check.sh" "$repo_root/android/royd/vendor/royd/bin/royd-binder-setup" "$repo_root/android/royd/vendor/royd/bin/royd-hardware-setup"; then
  printf '%s
' 'error: host GPU probing must not assume renderD128' >&2
  exit 1
fi
grep -Fq 'android-build-host-gpu-arm64' "$repo_root/Makefile"
grep -Fq 'runtime-import-host-gpu-arm64' "$repo_root/Makefile"
printf '%s\n' 'Runtime GPU contract test passed'
