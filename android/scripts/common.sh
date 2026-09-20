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
  printf 'error: unsupported Android version: %s; expected one of 14, 15, 16, 17\n' "$android_version" >&2
  exit 1
}
# shellcheck disable=SC1090
. "$version_env"

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

source_dir() {
  printf '%s\n' "${ROYD_ANDROID_SRC:-$repo_root/.work/android-src-$ANDROID_VERSION}"
}
