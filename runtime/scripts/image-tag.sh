#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
# shellcheck disable=SC1091
. "$repo_root/android/baseline.env"
# shellcheck disable=SC1091
. "$repo_root/runtime/image.env"

arch=${1:-x86_64}
profile=${2:-${ROYD_ANDROID_PROFILE:-standard}}
profile=$($repo_root/android/scripts/profile.sh "$profile")

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
printf '%s:%s-%s-%s\n' "$ROYD_IMAGE_REPOSITORY" "$version" "$profile" "$platform_arch"
