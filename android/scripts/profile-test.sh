#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
tmp=$(mktemp -d)
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT HUP INT TERM

[ "$("$script_dir/profile.sh" standard)" = standard ]
[ "$("$script_dir/profile.sh" minimal)" = minimal ]
if "$script_dir/profile.sh" missing >/dev/null 2>&1; then
  printf '%s\n' 'error: unknown Android image profile unexpectedly succeeded' >&2
  exit 1
fi

grep -Fq 'ro.vendor.royd.image_profile=standard' "$script_dir/../profiles/standard.mk"
grep -Fq 'ro.vendor.royd.image_profile=minimal' "$script_dir/../profiles/minimal.mk"
grep -Fq 'PrintSpooler' "$script_dir/../profiles/minimal.mk"

mkdir -p "$tmp/device/redroid"
printf '%s\n' '# fake ReDroid product' >"$tmp/device/redroid/redroid.mk"
"$script_dir/install-royd.sh" "$tmp" standard >/dev/null
grep -Fq 'ro.vendor.royd.image_profile=standard' "$tmp/vendor/royd/profile.mk"
"$script_dir/install-royd.sh" "$tmp" minimal >/dev/null
grep -Fq 'ro.vendor.royd.image_profile=minimal' "$tmp/vendor/royd/profile.mk"
[ "$(grep -Fc '$(call inherit-product, vendor/royd/royd.mk)' "$tmp/device/redroid/redroid.mk")" -eq 1 ]

printf '%s\n' 'Android image profile checks passed'
