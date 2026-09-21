#!/bin/sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
tmp=$(mktemp -d)
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT INT TERM

make_tree() {
  tree=$1
  mkdir -p "$tree/build" "$tree/frameworks/native/libs/binder/include/binder"
}

for hal_profile in graphical headless; do
  tree="$tmp/$hal_profile"
  make_tree "$tree"
  ROYD_ANDROID_SRC="$tree" ROYD_HAL_PROFILE="$hal_profile" "$script_dir/install-royd.sh" "$tree" standard >/dev/null
  grep -Fq "ro.vendor.royd.hal_profile=$hal_profile" "$tree/vendor/royd/hal_profile.mk"
  grep -Fq 'android.hardware.graphics.allocator-service.royd' "$tree/vendor/royd/graphics_backend.mk"
  grep -Fq 'android.hardware.graphics.composer3-service.royd' "$tree/vendor/royd/graphics_backend.mk"
  grep -Fq 'vendor/royd/hal_profile.mk' "$tree/vendor/royd/royd.mk"
  grep -Fq 'vendor/royd/graphics_backend.mk' "$tree/vendor/royd/royd.mk"
done

grep -Fq 'Camera2' "$tmp/headless/vendor/royd/hal_profile.mk"
! grep -Fq 'Camera2' "$tmp/graphical/vendor/royd/hal_profile.mk"
printf '%s\n' 'Android HAL contract test passed'
