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
cc -std=c11 -Wall -Wextra -Werror -I"$tmp" "$android_dir/tests/display-bootstrap-test.c" \
  -o "$tmp/display-bootstrap-test"
"$tmp/display-bootstrap-test"
if [ "${ROYD_DISPLAY_TEST_SANITIZERS:-0}" = 1 ]; then
  cc -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined -fno-omit-frame-pointer \
    -I"$tmp" "$android_dir/tests/display-bootstrap-test.c" -o "$tmp/display-bootstrap-sanitized"
  "$tmp/display-bootstrap-sanitized"
fi
printf '%s\n' 'ROYD_ANDROID_VERSION=15' 'ROYD_HAL_PROFILE=graphical' >"$tmp/release"
for resource_profile in low-memory performance; do
  ROYD_RELEASE_FILE="$tmp/release" ROYD_RUNTIME_CONFIG="$tmp/runtime.conf" \
    ROYD_RESOURCE_CONFIG="$tmp/resource.prop" ROYD_ENTRYPOINT_TEST_ONLY=1 \
    sh "$android_dir/../runtime/rootfs/royd-entrypoint" royd.width=600 royd.height=1000 \
      royd.dpi=320 royd.fps=24 "royd.resource_profile=$resource_profile"
  "$tmp/display-bootstrap-test" "$tmp/runtime.conf"
done
grep -Fq 'name: "royd-display-bootstrap"' "$android_dir/royd/vendor/royd/Android.bp"
grep -Fq 'exec -- /vendor/bin/royd-display-bootstrap' "$android_dir/royd/vendor/royd/init.royd.rc"
grep -Fq 'vendor.royd.display.width' "$android_dir/royd/vendor/royd/gralloc/gralloc_royd.cpp"
grep -Fq 'vendor.royd.display.ready' "$source_file"
! grep -R -Fq 'royd-display-setup' "$android_dir/royd/vendor/royd"
! grep -Fq 'ro.boot.royd_' "$android_dir/royd/vendor/royd/gralloc/gralloc_royd.cpp"
printf '%s\n' 'Android early display contract test passed'
