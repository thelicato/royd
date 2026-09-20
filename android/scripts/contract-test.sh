#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1091
. "$script_dir/common.sh"

for family in legacy transitional modern; do
  compat="$android_dir/compat/$family"
  [ -f "$compat/product.mk" ] || fail "missing $family product compatibility fragment"
  [ -f "$compat/BoardConfigVersion.mk" ] || fail "missing $family board compatibility fragment"
  [ -f "$compat/vendor.mk" ] || fail "missing $family vendor compatibility fragment"
done

for version in $("$script_dir/version-list.sh"); do
  ROYD_ANDROID_VERSION="$version" "$script_dir/contract-lines.sh" >/dev/null
  family=$(sh -c '. "$1"; printf "%s" "$ANDROID_PRODUCT_FAMILY"' sh "$android_dir/versions/$version.env")
  [ -d "$android_dir/compat/$family" ] || fail "Android $version references missing compatibility family $family"
done

printf '%s
' 'Android static build contract checks passed'
