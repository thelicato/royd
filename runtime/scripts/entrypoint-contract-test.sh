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
  shift 2
  ROYD_RELEASE_FILE="$release" \
    ROYD_RUNTIME_CONFIG="$output" \
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
run_entrypoint "$tmp/graphical-release" "$tmp/graphical.conf" \
  royd.width=360 royd.height=640 royd.dpi=160 royd.fps=24
cat > "$tmp/graphical.expected" <<'EOF_EXPECTED'
ROYD_WIDTH=360
ROYD_HEIGHT=640
ROYD_DPI=160
ROYD_FPS=24
EOF_EXPECTED
cmp "$tmp/graphical.expected" "$tmp/graphical.conf"

cat > "$tmp/non-executable-release" <<EOF_RELEASE
ROYD_HAL_PROFILE=graphical
UNUSED_METADATA=\$(touch "$tmp/metadata-executed")
ANDROID_REQUIRED_PARTITIONS=system vendor system_ext product
EOF_RELEASE
run_entrypoint "$tmp/non-executable-release" "$tmp/non-executable.conf"
[ ! -e "$tmp/metadata-executed" ]

cat > "$tmp/headless-release" <<'REL'
ROYD_HAL_PROFILE=headless
REL
run_entrypoint "$tmp/headless-release" "$tmp/headless.conf"
cat > "$tmp/headless.expected" <<'EOF_EXPECTED'
ROYD_WIDTH=64
ROYD_HEIGHT=64
ROYD_DPI=72
ROYD_FPS=5
EOF_EXPECTED
cmp "$tmp/headless.expected" "$tmp/headless.conf"

if run_entrypoint "$tmp/graphical-release" "$tmp/invalid.conf" royd.width=0 >/dev/null 2>&1; then
  printf '%s\n' 'error: entrypoint accepted an invalid display value' >&2
  exit 1
fi
if run_entrypoint "$tmp/graphical-release" "$tmp/invalid.conf" unknown=value >/dev/null 2>&1; then
  printf '%s\n' 'error: entrypoint accepted an unknown runtime argument' >&2
  exit 1
fi

grep -Fq 'exec /init' "$entrypoint"
! grep -Fq 'androidboot.' "$entrypoint"
printf '%s\n' 'Runtime entrypoint contract test passed'
