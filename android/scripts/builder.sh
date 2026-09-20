#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
android_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
repo_root=$(CDPATH= cd -- "$android_dir/.." && pwd)
image=${ROYD_BUILDER_IMAGE:-royd-android-builder}
work_dir=${ROYD_WORK_DIR:-$repo_root/.work}

command -v docker >/dev/null 2>&1 || {
  printf '%s\n' 'error: docker is required to run the Android builder container' >&2
  exit 1
}

mkdir -p "$work_dir"

docker build \
  --build-arg UID="$(id -u)" \
  --build-arg GID="$(id -g)" \
  -t "$image" \
  "$android_dir/builder"

docker run --rm -it \
  --privileged \
  -v "$repo_root:/workspace/royd" \
  -v "$work_dir:/workspace/royd/.work" \
  -w /workspace/royd \
  "$image" \
  "$@"
