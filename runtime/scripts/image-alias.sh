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
profile=${2:-standard}
profile=$($repo_root/android/scripts/profile.sh "$profile")

if [ "$ANDROID_VERSION" = "$ROYD_DEFAULT_ANDROID_VERSION" ]; then
  version_suffix=
else
  version_suffix="-$ANDROID_VERSION"
fi

case "$arch:$profile" in
  x86_64:standard) suffix="dev$version_suffix" ;;
  x86_64:*) suffix="dev$version_suffix-$profile" ;;
  arm64:standard) suffix="dev$version_suffix-arm64" ;;
  arm64:*) suffix="dev$version_suffix-$profile-arm64" ;;
  *)
    printf 'error: unsupported architecture: %s; expected x86_64 or arm64\n' "$arch" >&2
    exit 1
    ;;
esac
printf '%s:%s\n' "$ROYD_IMAGE_REPOSITORY" "$suffix"
