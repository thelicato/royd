#!/bin/sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
tmp=$(mktemp -d)
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT INT TERM
mkdir "$tmp/bin"
cat > "$tmp/bin/docker" <<'MOCK'
#!/bin/sh
[ "$1 $2" = 'image inspect' ] || exit 1
printf '%s\n' "${MOCK_IMAGE_ID:-sha256:fixture}"
MOCK
chmod +x "$tmp/bin/docker"
export PATH="$tmp/bin:$PATH"
cat > "$tmp/runner" <<'MOCK'
#!/bin/sh
set -eu
[ ! -e "$ROYD_RUNTIME_RESULT_FILE" ] || exit 2
mkdir -p "$(dirname -- "$ROYD_RUNTIME_RESULT_FILE")"
printf 'run %s %s\n' "$ROYD_ANDROID_VERSION" "$ROYD_QUALIFY_ARCH" >> "$MOCK_CALLS"
result=pass
[ "${MOCK_FAIL_ARCH:-}" != "$ROYD_QUALIFY_ARCH" ] || result=fail
cat > "$ROYD_RUNTIME_RESULT_FILE" <<RESULT
RESULT_FORMAT=5
ANDROID_VERSION=$ROYD_ANDROID_VERSION
ARCH=$ROYD_QUALIFY_ARCH
IMAGE_ID=${MOCK_IMAGE_ID:-sha256:fixture}
IMAGE_PROFILE=$ROYD_ANDROID_PROFILE
PROFILE_POLICY=$ROYD_EXPECTED_PROFILE_POLICY
PROFILE_POLICY_SHA256=$ROYD_EXPECTED_PROFILE_POLICY_SHA256
HAL_PROFILE=$ROYD_HAL_PROFILE
SECURITY_MODE=$ROYD_SECURITY_MODE
SECURITY_PROFILE=$ROYD_EXPECTED_SECURITY_PROFILE
SECURITY_PROFILE_SHA256=$ROYD_EXPECTED_SECURITY_PROFILE_SHA256
RESOURCE_PROFILE=${ROYD_RESOURCE_PROFILE:-low-memory}
HOST_STATUS=$result
IMAGE_STATUS=$result
BOOT_STATUS=$result
HEALTH_STATUS=$result
RUNTIME_STATUS=$result
SECURITY_STATUS=$result
SECURITY_EVIDENCE_STATUS=$result
GRAPHICS_STATUS=$result
LOGS_STATUS=$result
ADB_STATUS=$result
BINDER_ISOLATION_STATUS=$result
CONTAINER_EVIDENCE_STATUS=$result
POST_HISTORY_STATUS=$result
MAIN_CLEANUP_STATUS=$result
RESULT_STATUS=$result
RESULT
evidence_dir=${ROYD_RUNTIME_RESULT_FILE%.env}.evidence
mkdir "$evidence_dir"
printf '%s\n' '[{}]' > "$evidence_dir/container-inspect.json"
printf '%s\n' 'mock container log' > "$evidence_dir/container.log"
printf '%s\n' 'status=running' > "$evidence_dir/state.txt"
: > "$ROYD_RUNTIME_LOG_FILE"
[ "$result" = pass ]
MOCK
chmod +x "$tmp/runner"
: > "$tmp/calls"
export ROYD_QUALIFY_VERSIONS=15 ROYD_QUALIFY_ARCHES=x86_64 ROYD_QUALIFY_RUNNER="$tmp/runner" MOCK_CALLS="$tmp/calls"
export ROYD_RUNTIME_RESULTS_DIR="$tmp/results" ROYD_RUNTIME_REPORT_OUTPUT="$tmp/report.md"
ROYD_QUALIFY_ARCHES='x86_64 arm64' "$script_dir/qualification-matrix.sh" >/dev/null
[ "$(wc -l < "$tmp/calls")" -eq 2 ]
grep -Fq '| 15 | x86_64 | pass | pass | pass | pass | pass | pass | pass | pass | pass | pass | pass | pass | pass |' "$tmp/report.md"
"$script_dir/qualification-matrix.sh" >/dev/null
[ "$(wc -l < "$tmp/calls")" -eq 2 ]

# Rejected resume states must preserve earlier output and never invoke a replacement.
for regression in missing-log package-policy security-policy resource-profile image format history cleanup no-resume; do
  case_dir="$tmp/$regression"
  cp -R "$tmp/results" "$case_dir"
  file="$case_dir/15/x86_64-standard-graphical-privileged.env"
  case "$regression" in
    missing-log) rm "${file%.env}.evidence/container.log" ;;
    package-policy) sed -i 's/^PROFILE_POLICY_SHA256=.*/PROFILE_POLICY_SHA256=stale/' "$file" ;;
    security-policy) sed -i 's/^SECURITY_PROFILE_SHA256=.*/SECURITY_PROFILE_SHA256=stale/' "$file" ;;
    resource-profile) sed -i 's/^RESOURCE_PROFILE=.*/RESOURCE_PROFILE=performance/' "$file" ;;
    image) sed -i 's/^IMAGE_ID=.*/IMAGE_ID=sha256:previous/' "$file" ;;
    format) sed -i 's/^RESULT_FORMAT=.*/RESULT_FORMAT=4/' "$file" ;;
    history) sed -i 's/^POST_HISTORY_STATUS=.*/POST_HISTORY_STATUS=fail/' "$file" ;;
    cleanup) sed -i 's/^MAIN_CLEANUP_STATUS=.*/MAIN_CLEANUP_STATUS=fail/' "$file" ;;
  esac
  before=$(sha256sum "$file")
  resume=1; [ "$regression" != no-resume ] || resume=0
  if ROYD_RUNTIME_RESULTS_DIR="$case_dir" ROYD_QUALIFY_RESUME="$resume" "$script_dir/qualification-matrix.sh" >"$tmp/$regression.log" 2>&1; then
    printf 'error: matrix reused or overwrote rejected state: %s\n' "$regression" >&2; exit 1
  fi
  [ "$before" = "$(sha256sum "$file")" ]
  [ "$(wc -l < "$tmp/calls")" -eq 2 ]
  grep -Fq 'select a fresh ROYD_RUNTIME_RESULTS_DIR' "$tmp/$regression.log"
done

# A fresh failed attempt is retained and rejects the matrix.
if ROYD_RUNTIME_RESULTS_DIR="$tmp/failed" ROYD_QUALIFY_ARCHES=arm64 MOCK_FAIL_ARCH=arm64 "$script_dir/qualification-matrix.sh" >/dev/null 2>&1; then
  printf '%s\n' 'error: qualification matrix accepted a failing tuple' >&2; exit 1
fi
grep -Fq 'RESULT_STATUS=fail' "$tmp/failed/15/arm64-standard-graphical-privileged.env"
printf '%s\n' 'Runtime qualification matrix test passed'
