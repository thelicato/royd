#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
# shellcheck disable=SC1091
. "$repo_root/android/baseline.env"
android_version=${ROYD_ANDROID_VERSION:-$ROYD_DEFAULT_ANDROID_VERSION}
version_env="$repo_root/android/versions/$android_version.env"
[ -f "$version_env" ] || {
  versions=$("$repo_root/android/scripts/version-list.sh" | tr '\n' ' ' | sed 's/ $//')
  printf 'error: unsupported Android version: %s; expected one of %s\n' "$android_version" "$versions" >&2
  exit 1
}
# shellcheck disable=SC1090
. "$version_env"
# shellcheck disable=SC1091
. "$repo_root/runtime/image.env"

arch=${1:-x86_64}
profile=${2:-${ROYD_ANDROID_PROFILE:-standard}}
profile=$($repo_root/android/scripts/profile.sh "$profile")
hal_profile=${ROYD_HAL_PROFILE:-graphical}
hal_profile=$("$repo_root/android/scripts/hal-profile.sh" "$hal_profile")

graphics_backend=${ROYD_GRAPHICS_BACKEND:-software}
graphics_backend=$(ROYD_GRAPHICS_ARCH="$arch" "$repo_root/android/scripts/graphics-backend.sh" "$graphics_backend" "$arch")
graphics_suffix=
[ "$graphics_backend" = software ] || graphics_suffix="-$graphics_backend"

case "$arch" in
  x86_64) platform_arch=amd64 ;;
  arm64) platform_arch=arm64 ;;
  *)
    printf 'error: unsupported architecture: %s; expected x86_64 or arm64\n' "$arch" >&2
    exit 1
    ;;
esac

version=${AOSP_TAG#android-}
version=$(printf '%s' "$version" | tr '_' '-')
printf '%s:%s-%s-%s%s-%s\n' "$ROYD_IMAGE_REPOSITORY" "$version" "$profile" "$hal_profile" "$graphics_suffix" "$platform_arch"
