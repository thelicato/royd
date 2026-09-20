#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
tmp=$(mktemp -d)
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT INT TERM

cat > "$tmp/runner" <<'MOCK'
#!/bin/sh
set -eu
mkdir -p "$(dirname -- "$ROYD_RUNTIME_RESULT_FILE")"
printf 'run %s %s\n' "$ROYD_ANDROID_VERSION" "$ROYD_QUALIFY_ARCH" >> "$MOCK_CALLS"
result=pass
if [ "${MOCK_FAIL_ARCH:-}" = "$ROYD_QUALIFY_ARCH" ]; then
  result=fail
fi
cat > "$ROYD_RUNTIME_RESULT_FILE" <<RESULT
RESULT_FORMAT=1
ANDROID_VERSION=$ROYD_ANDROID_VERSION
ARCH=$ROYD_QUALIFY_ARCH
IMAGE_PROFILE=$ROYD_ANDROID_PROFILE
HAL_PROFILE=$ROYD_HAL_PROFILE
SECURITY_MODE=$ROYD_SECURITY_MODE
HOST_STATUS=$result
IMAGE_STATUS=$result
BOOT_STATUS=$result
HEALTH_STATUS=$result
RUNTIME_STATUS=$result
SECURITY_STATUS=$result
GRAPHICS_STATUS=$result
LOGS_STATUS=$result
ADB_STATUS=$result
BINDER_ISOLATION_STATUS=$result
RESULT_STATUS=$result
RESULT
: > "$ROYD_RUNTIME_LOG_FILE"
[ "$result" = pass ]
MOCK
chmod +x "$tmp/runner"
: > "$tmp/calls"

ROYD_QUALIFY_VERSIONS=15 \
ROYD_QUALIFY_ARCHES='x86_64 arm64' \
ROYD_QUALIFY_RUNNER="$tmp/runner" \
ROYD_RUNTIME_RESULTS_DIR="$tmp/results" \
ROYD_RUNTIME_REPORT_OUTPUT="$tmp/report.md" \
MOCK_CALLS="$tmp/calls" \
"$script_dir/qualification-matrix.sh" >/dev/null
[ "$(wc -l < "$tmp/calls" | tr -d ' ')" -eq 2 ]
grep -Fq '| 15 | x86_64 | pass | pass | pass | pass | pass | pass | pass | pass | pass | pass | pass |' "$tmp/report.md"

# Resume must skip already-passing tuples.
ROYD_QUALIFY_VERSIONS=15 \
ROYD_QUALIFY_ARCHES=x86_64 \
ROYD_QUALIFY_RUNNER="$tmp/runner" \
ROYD_RUNTIME_RESULTS_DIR="$tmp/results" \
ROYD_RUNTIME_REPORT_OUTPUT="$tmp/report.md" \
MOCK_CALLS="$tmp/calls" \
"$script_dir/qualification-matrix.sh" >/dev/null
[ "$(wc -l < "$tmp/calls" | tr -d ' ')" -eq 2 ]

# A failing tuple must be persisted and make the matrix fail.
if ROYD_QUALIFY_VERSIONS=15 \
  ROYD_QUALIFY_ARCHES=arm64 \
  ROYD_QUALIFY_RESUME=0 \
  ROYD_QUALIFY_RUNNER="$tmp/runner" \
  ROYD_RUNTIME_RESULTS_DIR="$tmp/results" \
  ROYD_RUNTIME_REPORT_OUTPUT="$tmp/report.md" \
  MOCK_CALLS="$tmp/calls" \
  MOCK_FAIL_ARCH=arm64 \
  "$script_dir/qualification-matrix.sh" >/dev/null 2>&1; then
  printf '%s\n' 'error: qualification matrix accepted a failing tuple' >&2
  exit 1
fi
grep -Fq 'RESULT_STATUS=fail' "$tmp/results/15/arm64-standard-graphical-privileged.env"

printf '%s\n' 'Runtime qualification matrix test passed'
