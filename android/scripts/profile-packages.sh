#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1091
. "$script_dir/common.sh"

profile=${1:-${ROYD_ANDROID_PROFILE:-standard}}
profile=$($script_dir/profile.sh "$profile")
protected="$android_dir/profiles/protected.packages"

clean_list() {
  sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$@" | LC_ALL=C sort -u
}

case "$profile" in
  standard)
    exit 0
    ;;
  minimal)
    common="$android_dir/profiles/minimal/common.packages"
    family="$android_dir/profiles/minimal/$ANDROID_PRODUCT_FAMILY.packages"
    [ -f "$common" ] || fail "minimal profile common package policy not found at $common"
    [ -f "$family" ] || fail "minimal profile package policy not found for family $ANDROID_PRODUCT_FAMILY"
    removals=$(clean_list "$common" "$family")
    protected_list=$(clean_list "$protected")
    overlap=$(printf '%s\n' "$removals" "$protected_list" | LC_ALL=C sort | uniq -d)
    [ -z "$overlap" ] || {
      printf 'error: minimal profile attempts to remove protected packages:\n%s\n' "$overlap" >&2
      exit 1
    }
    printf '%s\n' "$removals"
    ;;
  *)
    fail "package policy is not defined for Android image profile $profile"
    ;;
esac
