#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
android_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
repo_root=$(CDPATH= cd -- "$android_dir/.." && pwd)

# shellcheck disable=SC1091
. "$android_dir/baseline.env"

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

source_dir() {
  printf '%s\n' "${ROYD_ANDROID_SRC:-$repo_root/.work/android-src}"
}
