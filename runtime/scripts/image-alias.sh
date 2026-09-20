#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
# shellcheck disable=SC1091
. "$repo_root/runtime/image.env"

arch=${1:-x86_64}
profile=${2:-standard}
profile=$($repo_root/android/scripts/profile.sh "$profile")

case "$arch:$profile" in
  x86_64:standard) suffix=dev ;;
  x86_64:*) suffix="dev-$profile" ;;
  arm64:standard) suffix=dev-arm64 ;;
  arm64:*) suffix="dev-$profile-arm64" ;;
  *)
    printf 'error: unsupported architecture: %s; expected x86_64 or arm64\n' "$arch" >&2
    exit 1
    ;;
esac
printf '%s:%s\n' "$ROYD_IMAGE_REPOSITORY" "$suffix"
