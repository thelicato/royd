#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
android_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
source_file="$android_dir/royd/vendor/royd/display/royd-display-bootstrap.c"
tmp=$(mktemp -d)
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT INT TERM

mkdir -p "$tmp/cutils"
cat > "$tmp/cutils/properties.h" <<'EOF_HEADER'
#ifndef ROYD_TEST_PROPERTIES_H
#define ROYD_TEST_PROPERTIES_H
#define PROPERTY_VALUE_MAX 92
int property_get(const char* key, char* value, const char* default_value);
int property_set(const char* key, const char* value);
#endif
EOF_HEADER

cc -std=c11 -Wall -Wextra -Werror -I"$tmp" -c "$source_file" -o "$tmp/display.o"
grep -Fq 'name: "royd-display-bootstrap"' "$android_dir/royd/vendor/royd/Android.bp"
grep -Fq 'exec -- /vendor/bin/royd-display-bootstrap' "$android_dir/royd/vendor/royd/init.royd.rc"
grep -Fq 'vendor.royd.display.width' "$android_dir/royd/vendor/royd/gralloc/gralloc_royd.cpp"
grep -Fq 'vendor.royd.display.ready' "$source_file"
! grep -R -Fq 'royd-display-setup' "$android_dir/royd/vendor/royd"
! grep -Fq 'ro.boot.royd_' "$android_dir/royd/vendor/royd/gralloc/gralloc_royd.cpp"
printf '%s\n' 'Android early display contract test passed'
