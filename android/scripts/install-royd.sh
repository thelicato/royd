#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1091
. "$script_dir/common.sh"

src=${1:-$(source_dir)}
profile=${2:-${ROYD_ANDROID_PROFILE:-standard}}
profile=$($script_dir/profile.sh "$profile")
royd_vendor_src="$android_dir/royd/vendor/royd"
royd_vendor_dst="$src/vendor/royd"
profile_src="$android_dir/profiles/$profile.mk"
profile_dst="$royd_vendor_dst/profile.mk"
redroid_product="$src/device/redroid/redroid.mk"
inherit_line='$(call inherit-product, vendor/royd/royd.mk)'

[ -d "$src/device/redroid" ] || fail "ReDroid device tree not found at $src/device/redroid"
[ -f "$redroid_product" ] || fail "ReDroid product file not found at $redroid_product"
[ -d "$royd_vendor_src" ] || fail "royd vendor source not found at $royd_vendor_src"

printf 'Installing royd Android integration with profile %s\n' "$profile"
rm -rf "$royd_vendor_dst"
mkdir -p "$royd_vendor_dst"
cp -a "$royd_vendor_src/." "$royd_vendor_dst/"
cp "$profile_src" "$profile_dst"

if ! grep -Fqx "$inherit_line" "$redroid_product"; then
  printf '\n# royd container integration\n%s\n' "$inherit_line" >> "$redroid_product"
fi
