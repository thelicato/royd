#!/bin/sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
android_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)

[ "$("$script_dir/hal-profile.sh" graphical)" = graphical ]
[ "$("$script_dir/hal-profile.sh" headless)" = headless ]
! "$script_dir/hal-profile.sh" invalid >/dev/null 2>&1

grep -Fq 'ro.vendor.royd.hal_profile=graphical' "$android_dir/hal-profiles/graphical.mk"
grep -Fq 'ro.vendor.royd.hal_profile=headless' "$android_dir/hal-profiles/headless.mk"
grep -Fq 'gralloc.royd' "$android_dir/hal-profiles/headless.mk"
grep -Fq 'hwcomposer.default' "$android_dir/hal-profiles/headless.mk"
grep -Fq 'Camera2' "$android_dir/hal-profiles/headless.mk"
printf '%s\n' 'Android HAL profile test passed'
