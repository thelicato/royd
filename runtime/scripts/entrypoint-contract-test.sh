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
