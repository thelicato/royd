#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM
work="$tmp/work"
mkdir -p "$work/android-src-15/build" "$work/build-results"
printf '<manifest revision="test"/>\n' > "$work/android-manifest-15.lock.xml"

cat > "$tmp/builder" <<'EOF_BUILDER'
#!/bin/sh
set -eu
printf '%s\n' "$*" >> "$ROYD_TEST_CALLS"
case "$1" in
  android/scripts/config-check.sh)
    if [ "${ROYD_TEST_FAIL_CONFIG:-0}" = 1 ]; then exit 1; fi
    ;;
  android/scripts/build.sh)
    if [ "${ROYD_TEST_FAIL_BUILD:-0}" = 1 ]; then exit 1; fi
    ;;
  android/scripts/package.sh)
    if [ "${ROYD_TEST_FAIL_PACKAGE:-0}" = 1 ]; then exit 1; fi
    mkdir -p "$ROYD_WORK_DIR/runtime/android-15"
    cat > "$ROYD_WORK_DIR/runtime/android-15/royd-$2-standard-graphical.manifest" <<EOF_MANIFEST
ARCHIVE_SHA256=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
EOF_MANIFEST
    ;;
esac
EOF_BUILDER
chmod +x "$tmp/builder"

calls="$tmp/calls"
report="$tmp/report.md"
export ROYD_TEST_CALLS="$calls"

ROYD_WORK_DIR="$work" \
ROYD_BUILD_VERSIONS=15 \
ROYD_BUILD_ARCHES='x86_64 arm64' \
ROYD_BUILD_BUILDER="$tmp/builder" \
ROYD_BUILD_RESULTS_DIR="$work/build-results" \
ROYD_BUILD_REPORT_OUTPUT="$report" \
ROYD_BUILD_CLEAN=1 \
ROYD_BUILD_RESUME=0 \
"$script_dir/build-matrix.sh"

grep -q '^android/scripts/config-check.sh x86_64$' "$calls"
grep -q '^android/scripts/build.sh x86_64 standard$' "$calls"
grep -q '^android/scripts/package.sh x86_64 standard$' "$calls"
grep -q '^android/scripts/config-check.sh arm64$' "$calls"
grep -q '^android/scripts/build.sh arm64 standard$' "$calls"
grep -q '^android/scripts/package.sh arm64 standard$' "$calls"

x86_result="$work/build-results/15/x86_64-standard-graphical.env"
grep -q '^RESULT_STATUS=pass$' "$x86_result"
grep -q '^CLEAN_BUILD=1$' "$x86_result"
grep -q '^STAGES=config build package$' "$x86_result"
grep -q '^SYNC_STATUS=not-needed$' "$x86_result"
grep -q '^CONFIG_STATUS=pass$' "$x86_result"
grep -q '^BUILD_STATUS=pass$' "$x86_result"
grep -q '^PACKAGE_STATUS=pass$' "$x86_result"
grep -q '^ARCHIVE_SHA256=0123456789abcdef' "$x86_result"
grep -q '| 15 | x86_64 | pass | pass | pass | pass |' "$report"

before=$(wc -l < "$calls" | tr -d ' ')
ROYD_WORK_DIR="$work" \
ROYD_BUILD_VERSIONS=15 \
ROYD_BUILD_ARCHES=x86_64 \
ROYD_BUILD_BUILDER="$tmp/builder" \
ROYD_BUILD_RESULTS_DIR="$work/build-results" \
ROYD_BUILD_REPORT_OUTPUT="$report" \
ROYD_BUILD_CLEAN=1 \
ROYD_BUILD_RESUME=1 \
"$script_dir/build-matrix.sh"
after=$(wc -l < "$calls" | tr -d ' ')
[ "$before" = "$after" ] || {
  printf '%s\n' 'error: resume mode reran a passing build tuple' >&2
  exit 1
}

# Changing the recorded package-policy digest must invalidate a passing tuple.
sed -i 's/^PROFILE_POLICY_SHA256=.*/PROFILE_POLICY_SHA256=stale/' "$x86_result"
ROYD_WORK_DIR="$work" \
ROYD_BUILD_VERSIONS=15 \
ROYD_BUILD_ARCHES=x86_64 \
ROYD_BUILD_BUILDER="$tmp/builder" \
ROYD_BUILD_RESULTS_DIR="$work/build-results" \
ROYD_BUILD_REPORT_OUTPUT="$report" \
ROYD_BUILD_CLEAN=1 \
ROYD_BUILD_RESUME=1 \
"$script_dir/build-matrix.sh" >/dev/null
policy_after=$(wc -l < "$calls" | tr -d ' ')
[ "$policy_after" -eq $((after + 3)) ] || {
  printf '%s\n' 'error: changed image-profile policy did not invalidate build-matrix resume state' >&2
  exit 1
}

rm -f "$work/build-results/15/arm64-standard-graphical.env"
if ROYD_TEST_FAIL_BUILD=1 \
  ROYD_WORK_DIR="$work" \
  ROYD_BUILD_VERSIONS=15 \
  ROYD_BUILD_ARCHES=arm64 \
  ROYD_BUILD_BUILDER="$tmp/builder" \
  ROYD_BUILD_RESULTS_DIR="$work/build-results" \
  ROYD_BUILD_REPORT_OUTPUT="$report" \
  ROYD_BUILD_RESUME=0 \
  "$script_dir/build-matrix.sh"; then
  printf '%s\n' 'error: failing build unexpectedly passed' >&2
  exit 1
fi

grep -q '^RESULT_STATUS=build-failed$' "$work/build-results/15/arm64-standard-graphical.env"
grep -q '^PACKAGE_STATUS=not-run$' "$work/build-results/15/arm64-standard-graphical.env"

printf '%s\n' 'Android clean-build matrix tests passed'
