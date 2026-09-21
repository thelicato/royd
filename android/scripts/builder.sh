#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
android_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
repo_root=$(CDPATH= cd -- "$android_dir/.." && pwd)
# shellcheck disable=SC1091
. "$android_dir/baseline.env"
android_version=${ROYD_ANDROID_VERSION:-$ROYD_DEFAULT_ANDROID_VERSION}
version_env="$android_dir/versions/$android_version.env"
[ -f "$version_env" ] || {
  versions=$("$android_dir/scripts/version-list.sh" | tr '\n' ' ' | sed 's/ $//')
  printf 'error: unsupported Android version: %s; expected one of %s\n' "$android_version" "$versions" >&2
  exit 1
}
# shellcheck disable=SC1090
. "$version_env"

family=${ANDROID_BUILDER_FAMILY:-modern}
case "$family" in
  modern)
    dockerfile="$android_dir/builder/Dockerfile"
    image=${ROYD_BUILDER_IMAGE:-royd-android-builder}
    ;;
  legacy)
    dockerfile="$android_dir/builder/Dockerfile.legacy"
    image=${ROYD_LEGACY_BUILDER_IMAGE:-royd-android-builder-legacy}
    ;;
  *)
    printf 'error: unsupported Android builder family: %s\n' "$family" >&2
    exit 1
    ;;
esac
work_dir=${ROYD_WORK_DIR:-$repo_root/.work}

host_uid=$(id -u)
host_gid=$(id -g)
build_uid=$host_uid
build_gid=$host_gid
if [ "$host_uid" -eq 0 ]; then
  build_uid=${ROYD_BUILD_UID:-1000}
  build_gid=${ROYD_BUILD_GID:-1000}
  case "$build_uid:$build_gid" in
    *[!0-9:]*|0:*|*:0|:)
      printf '%s\n' 'error: ROYD_BUILD_UID and ROYD_BUILD_GID must be non-zero numeric IDs when the host user is root' >&2
      exit 1
      ;;
  esac
fi

command -v docker >/dev/null 2>&1 || {
  printf '%s\n' 'error: docker is required to run the Android builder container' >&2
  exit 1
}

mkdir -p "$work_dir"
if [ "$host_uid" -eq 0 ]; then
  chown "$build_uid:$build_gid" "$work_dir"
fi
printf 'Using %s Android builder for Android %s as UID/GID %s:%s\n' "$family" "$android_version" "$build_uid" "$build_gid"

tty_mode=${ROYD_BUILDER_TTY:-auto}
case "$tty_mode" in
  auto)
    if [ -t 0 ] && [ -t 1 ]; then
      tty_args='-it'
    else
      tty_args=
    fi
    ;;
  always)
    tty_args='-it'
    ;;
  never)
    tty_args=
    ;;
  *)
    printf 'error: unsupported ROYD_BUILDER_TTY value: %s; expected auto, always or never\n' "$tty_mode" >&2
    exit 1
    ;;
esac
docker build \
  -f "$dockerfile" \
  --build-arg UID="$build_uid" \
  --build-arg GID="$build_gid" \
  -t "$image" \
  "$android_dir/builder"

docker run --rm $tty_args \
  --privileged \
  -e JOBS="${JOBS:-}" \
  -e ROYD_CLEAN_BUILD="${ROYD_CLEAN_BUILD:-0}" \
  -e ROYD_ANDROID_VERSION="$android_version" \
  -e ROYD_ANDROID_PROFILE="${ROYD_ANDROID_PROFILE:-standard}" \
  -e ROYD_HAL_PROFILE="${ROYD_HAL_PROFILE:-graphical}" \
  -e ROYD_GRAPHICS_BACKEND="${ROYD_GRAPHICS_BACKEND:-software}" \
  -v "$repo_root:/workspace/royd" \
  -v "$work_dir:/workspace/royd/.work" \
  -w /workspace/royd \
  "$image" \
  "$@"
