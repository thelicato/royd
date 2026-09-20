#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1091
. "$script_dir/common.sh"

profile=${1:-${ROYD_ANDROID_PROFILE:-standard}}
profile=$($script_dir/profile.sh "$profile")

case "$profile" in
  standard) printf '%s\n' standard-v1 ;;
  minimal) printf 'minimal-v2-%s\n' "$ANDROID_PRODUCT_FAMILY" ;;
  *) fail "profile policy is not defined for Android image profile $profile" ;;
esac
