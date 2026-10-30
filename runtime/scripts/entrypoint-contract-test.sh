#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
entrypoint="$repo_root/runtime/rootfs/royd-entrypoint"
tmp=$(mktemp -d)
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT INT TERM

run_entrypoint() {
  release=$1
  output=$2
  resource_output=$3
  shift 3
  ROYD_RELEASE_FILE="$release" \
    ROYD_RUNTIME_CONFIG="$output" \
    ROYD_RESOURCE_CONFIG="$resource_output" \
    ROYD_ENTRYPOINT_TEST_ONLY=1 \
    sh "$entrypoint" "$@"
}

cat > "$tmp/graphical-release" <<'REL'
ROYD_IMAGE_FORMAT=1
ROYD_ANDROID_VERSION=15
ROYD_HAL_PROFILE=graphical
ANDROID_REQUIRED_PARTITIONS=system vendor system_ext product
ANDROID_MEMORY_COMPAT=cgroup-v2
REL
run_entrypoint "$tmp/graphical-release" "$tmp/graphical.conf" "$tmp/graphical-resource.prop" \
  royd.width=360 royd.height=640 royd.dpi=160 royd.fps=24
cat > "$tmp/graphical.expected" <<'EOF_EXPECTED'
ROYD_WIDTH=360
ROYD_HEIGHT=640
ROYD_DPI=160
ROYD_FPS=24
ROYD_RESOURCE_PROFILE=low-memory
EOF_EXPECTED
cmp "$tmp/graphical.expected" "$tmp/graphical.conf"
cat > "$tmp/graphical-resource.expected" <<'EOF_EXPECTED'
ro.vendor.royd.resource_profile=low-memory
ro.config.low_ram=true
ro.config.per_app_memcg=true
dalvik.vm.heapstartsize=5m
dalvik.vm.heapgrowthlimit=48m
dalvik.vm.heapsize=128m
dalvik.vm.heaptargetutilization=0.75
dalvik.vm.heapminfree=512k
dalvik.vm.heapmaxfree=2m
ro.sf.lcd_density=160
ro.adb.secure=0
EOF_EXPECTED
cmp "$tmp/graphical-resource.expected" "$tmp/graphical-resource.prop"

run_entrypoint "$tmp/graphical-release" "$tmp/performance.conf" \
  "$tmp/performance-resource.prop" royd.resource_profile=performance
grep -Fxq 'ROYD_RESOURCE_PROFILE=performance' "$tmp/performance.conf"
cat > "$tmp/performance-resource.expected" <<'EOF_EXPECTED'
ro.vendor.royd.resource_profile=performance
ro.config.low_ram=false
ro.config.per_app_memcg=true
dalvik.vm.heapstartsize=8m
dalvik.vm.heapgrowthlimit=192m
dalvik.vm.heapsize=512m
dalvik.vm.heaptargetutilization=0.75
dalvik.vm.heapminfree=512k
dalvik.vm.heapmaxfree=8m
ro.sf.lcd_density=240
ro.adb.secure=0
EOF_EXPECTED
cmp "$tmp/performance-resource.expected" "$tmp/performance-resource.prop"

cat > "$tmp/non-executable-release" <<EOF_RELEASE
ROYD_HAL_PROFILE=graphical
UNUSED_METADATA=\$(touch "$tmp/metadata-executed")
ANDROID_REQUIRED_PARTITIONS=system vendor system_ext product
EOF_RELEASE
run_entrypoint "$tmp/non-executable-release" "$tmp/non-executable.conf" \
  "$tmp/non-executable-resource.prop"
[ ! -e "$tmp/metadata-executed" ]

# The pre-init success path must not depend on external utilities. Android's
# bootstrap shell is available before the normal runtime linker/APEX setup is.
PATH="$tmp/no-external-tools" \
  ROYD_RELEASE_FILE="$tmp/graphical-release" \
  ROYD_RUNTIME_CONFIG="$tmp/builtin-only.conf" \
  ROYD_RESOURCE_CONFIG="$tmp/builtin-only-resource.prop" \
  ROYD_ENTRYPOINT_TEST_ONLY=1 \
  /bin/sh "$entrypoint" royd.width=360 royd.height=640 royd.dpi=160 royd.fps=24
cmp "$tmp/graphical.expected" "$tmp/builtin-only.conf"
cmp "$tmp/graphical-resource.expected" "$tmp/builtin-only-resource.prop"

# Authentication is selected before init publishes read-only boot properties.
# Its required mode must also work without pre-init external tools.
PATH="$tmp/no-external-tools" \
  ROYD_RELEASE_FILE="$tmp/graphical-release" \
  ROYD_RUNTIME_CONFIG="$tmp/auth.conf" \
  ROYD_RESOURCE_CONFIG="$tmp/auth.prop" \
  ROYD_ENTRYPOINT_TEST_ONLY=1 \
  /bin/sh "$entrypoint" royd.adb_auth=required \
    royd.width=360 royd.height=640 royd.dpi=160 royd.fps=24
cmp "$tmp/graphical.expected" "$tmp/auth.conf"
sed 's/ro.adb.secure=0/ro.adb.secure=1/' "$tmp/graphical-resource.expected" >"$tmp/auth.expected"
cmp "$tmp/auth.expected" "$tmp/auth.prop"
for invalid_auth in '' true false 0 1 optional Required; do
  if run_entrypoint "$tmp/graphical-release" "$tmp/bad-auth.conf" "$tmp/bad-auth.prop" \
      "royd.adb_auth=$invalid_auth" >/dev/null 2>&1; then
    printf 'error: entrypoint accepted invalid ADB authentication mode: %s\n' "$invalid_auth" >&2
    exit 1
  fi
done

if grep -Eq '(^|[[:space:]])printf([[:space:]]|$)' "$entrypoint"; then
  printf '%s\n' 'error: pre-init entrypoint must not use printf' >&2
  exit 1
fi

cat > "$tmp/headless-release" <<'REL'
ROYD_HAL_PROFILE=headless
REL
run_entrypoint "$tmp/headless-release" "$tmp/headless.conf" "$tmp/headless-resource.prop"
cat > "$tmp/headless.expected" <<'EOF_EXPECTED'
ROYD_WIDTH=64
ROYD_HEIGHT=64
ROYD_DPI=72
ROYD_FPS=5
ROYD_RESOURCE_PROFILE=low-memory
EOF_EXPECTED
cmp "$tmp/headless.expected" "$tmp/headless.conf"
! grep -q '^ro.sf.lcd_density=' "$tmp/headless-resource.prop"
! grep -q '^ro.sf.lcd_density=' "$tmp/non-executable-resource.prop"

for selected_dpi in 1 160 240 320 2000 000240; do
  run_entrypoint "$tmp/graphical-release" "$tmp/density.conf" "$tmp/density.prop" \
    "royd.dpi=$selected_dpi"
  expected_dpi=$selected_dpi
  [ "$selected_dpi" != 000240 ] || expected_dpi=240
  grep -Fxq "ROYD_DPI=$expected_dpi" "$tmp/density.conf"
  grep -Fxq "ro.sf.lcd_density=$expected_dpi" "$tmp/density.prop"
done
for invalid_dpi in 0 00 000 2001 99999 999999999999999999999999; do
  if run_entrypoint "$tmp/graphical-release" "$tmp/bad-density.conf" "$tmp/bad-density.prop" \
      "royd.dpi=$invalid_dpi" >/dev/null 2>&1; then
    printf 'error: entrypoint accepted invalid Android 15 dpi: %s\n' "$invalid_dpi" >&2
    exit 1
  fi
done
for version in 8.0 14 16 17; do
  printf 'ROYD_ANDROID_VERSION=%s\nROYD_HAL_PROFILE=graphical\n' "$version" >"$tmp/other-release"
  run_entrypoint "$tmp/other-release" "$tmp/other.conf" "$tmp/other.prop"
  ! grep -q '^ro.sf.lcd_density=' "$tmp/other.prop"
  ! grep -q '^ro.adb.secure=' "$tmp/other.prop"
  if run_entrypoint "$tmp/other-release" "$tmp/unsupported-auth.conf" "$tmp/unsupported-auth.prop" \
      royd.adb_auth=required >/dev/null 2>&1; then
    printf 'error: entrypoint enabled required ADB authentication on Android %s\n' "$version" >&2
    exit 1
  fi
done

if run_entrypoint "$tmp/headless-release" "$tmp/no-version-auth.conf" "$tmp/no-version-auth.prop" \
    royd.adb_auth=required >/dev/null 2>&1; then
  printf '%s\n' 'error: entrypoint enabled required ADB authentication without version metadata' >&2
  exit 1
fi

# The built-in Android 15 default must remain authenticated if loading fails.
for sdk in 34 35 36; do
  expected_secure=0
  [ "$sdk" != 35 ] || expected_secure=1
  actual_property=$(make -s --no-print-directory -f - PLATFORM_SDK_VERSION="$sdk" <<EOF_MAKE
include $repo_root/android/compat/modern/vendor.mk
all:
	@echo \$(PRODUCT_SYSTEM_DEFAULT_PROPERTIES)
EOF_MAKE
  )
  [ "$actual_property" = "ro.adb.secure=$expected_secure" ]
done

if run_entrypoint "$tmp/graphical-release" "$tmp/invalid.conf" "$tmp/invalid-resource.prop" \
    royd.width=0 >/dev/null 2>&1; then
  printf '%s\n' 'error: entrypoint accepted an invalid display value' >&2
  exit 1
fi
if run_entrypoint "$tmp/graphical-release" "$tmp/invalid.conf" "$tmp/invalid-resource.prop" \
    unknown=value >/dev/null 2>&1; then
  printf '%s\n' 'error: entrypoint accepted an unknown runtime argument' >&2
  exit 1
fi
if run_entrypoint "$tmp/graphical-release" "$tmp/invalid.conf" "$tmp/invalid-resource.prop" \
    royd.resource_profile=unknown >/dev/null 2>&1; then
  printf '%s\n' 'error: entrypoint accepted an unknown resource profile' >&2
  exit 1
fi
if run_entrypoint "$tmp/headless-release" "$tmp/invalid.conf" "$tmp/invalid-resource.prop" \
    royd.resource_profile=performance >/dev/null 2>&1; then
  printf '%s\n' 'error: entrypoint enabled the Android 15 performance profile without version metadata' >&2
  exit 1
fi

grep -Fq 'exec /init' "$entrypoint"
! grep -Fq 'androidboot.' "$entrypoint"
printf '%s\n' 'Runtime entrypoint contract test passed'
