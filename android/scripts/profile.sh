#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1091
. "$script_dir/common.sh"

profile=${1:-${ROYD_ANDROID_PROFILE:-standard}}
profile_file="$android_dir/profiles/$profile.mk"

[ -f "$profile_file" ] || {
  printf 'error: unknown Android image profile: %s\n' "$profile" >&2
  printf 'available profiles:' >&2
  for candidate in "$android_dir"/profiles/*.mk; do
    [ -e "$candidate" ] || continue
    name=${candidate##*/}
    printf ' %s' "${name%.mk}" >&2
  done
  printf '\n' >&2
  exit 2
}

printf '%s\n' "$profile"
