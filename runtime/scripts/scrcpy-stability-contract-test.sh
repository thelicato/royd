#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
tmp=$(mktemp -d)
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT HUP INT TERM
mkdir -p "$tmp/bin"

cat >"$tmp/bin/docker" <<'MOCK'
#!/bin/sh
set -eu
printf '%s\n' "$*" >>"$MOCK_DOCKER_LOG"
case "$*" in
  'image inspect --format {{.Id}} '*) printf '%s\n' sha256:scrcpy-image ;;
  'image inspect '*) exit 0 ;;
  'volume create '*) printf '%s\n' mock-volume ;;
  'run -d '*) printf '%s\n' mock-container ;;
  'port '*' 5555/tcp') printf '%s\n' '127.0.0.1:40123' ;;
  'inspect '*) printf '%s\n' '[{"State":{"Running":true}}]' ;;
  'logs '*) printf '%s\n' '[royd] mock log' ;;
  'rm -f '*|'volume rm '*) exit 0 ;;
  *) printf 'unexpected docker command: %s\n' "$*" >&2; exit 1 ;;
esac
MOCK
chmod +x "$tmp/bin/docker"

cat >"$tmp/bin/adb" <<'MOCK'
#!/bin/sh
set -eu
printf '%s\n' "$*" >>"$MOCK_ADB_LOG"
case "$*" in
  '-s 127.0.0.1:40123 get-state') printf '%s\n' device ;;
  *) exit 0 ;;
esac
MOCK
chmod +x "$tmp/bin/adb"

cat >"$tmp/bin/scrcpy" <<'MOCK'
#!/bin/sh
set -eu
case "$*" in
  '--version') printf '%s\n' 'scrcpy 5.0' ; exit 0 ;;
esac
printf '%s\n' "$*" >>"$MOCK_SCRCPY_LOG"
recording=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --record) shift; recording=$1 ;;
  esac
  shift
done
[ -n "$recording" ]
dd if=/dev/zero of="$recording" bs=1024 count=4 2>/dev/null
sleep 1
MOCK
chmod +x "$tmp/bin/scrcpy"

cat >"$tmp/bin/pass" <<'MOCK'
#!/bin/sh
exit 0
MOCK
chmod +x "$tmp/bin/pass"

cat >"$tmp/bin/assert" <<'MOCK'
#!/bin/sh
set -eu
printf '%s\n' "$*" >>"$MOCK_ASSERT_LOG"
if [ "${MOCK_FAIL_POST:-0}" = 1 ] && [ "$(wc -l <"$MOCK_ASSERT_LOG")" -eq 2 ]; then
  printf '%s\n' 'mock post-workload runtime failure'
  exit 1
fi
MOCK
chmod +x "$tmp/bin/assert"

: >"$tmp/docker.log"
: >"$tmp/adb.log"
: >"$tmp/scrcpy.log"
PATH="$tmp/bin:$PATH" \
MOCK_DOCKER_LOG="$tmp/docker.log" MOCK_ADB_LOG="$tmp/adb.log" \
MOCK_SCRCPY_LOG="$tmp/scrcpy.log" ROYD_DOCKER_COMMAND=docker \
MOCK_ASSERT_LOG="$tmp/assert.log" \
ROYD_ADB_COMMAND=adb ROYD_SCRCPY_COMMAND=scrcpy \
ROYD_SCRCPY_WAIT_RUNNER="$tmp/bin/pass" ROYD_SCRCPY_HEALTH_RUNNER="$tmp/bin/pass" \
ROYD_SCRCPY_ASSERT_RUNNER="$tmp/bin/assert" \
ROYD_SCRCPY_DURATION=1 ROYD_SCRCPY_MINIMUM_BYTES=1024 \
ROYD_SCRCPY_OUTPUT_DIR="$tmp/evidence" \
  "$script_dir/scrcpy-stability-test.sh" royd:test >/dev/null

grep -Fqx 'ROYD_SCRCPY_EVIDENCE_FORMAT=2' "$tmp/evidence/manifest.env"
grep -Fqx 'RESULT_STATUS=pass' "$tmp/evidence/manifest.env"
grep -Fqx 'POST_RUNTIME_STATUS=pass' "$tmp/evidence/manifest.env"
[ -f "$tmp/evidence/post-runtime.log" ]
[ "$(wc -l <"$tmp/assert.log")" -eq 2 ]
grep -Fqx 'IMAGE_ID=sha256:scrcpy-image' "$tmp/evidence/manifest.env"
grep -Fqx 'REQUESTED_DURATION_SECONDS=1' "$tmp/evidence/manifest.env"
grep -Fqx 'SCRCPY_VERSION=scrcpy 5.0' "$tmp/evidence/manifest.env"
[ -s "$tmp/evidence/scrcpy.mp4" ]
[ -f "$tmp/evidence/.royd-scrcpy-evidence" ]
[ -f "$tmp/evidence/container-inspect.json" ]
[ -f "$tmp/evidence/container.log" ]
grep -Fq -- '--no-window --no-audio --video-codec=h264' "$tmp/scrcpy.log"
grep -Fq -- '--start-app=+com.android.settings' "$tmp/scrcpy.log"
grep -Fq 'port royd-scrcpy-' "$tmp/docker.log"
grep -Fq 'connect 127.0.0.1:40123' "$tmp/adb.log"
grep -Fq -- '-L tcp:localhost:5038 start-server' "$tmp/adb.log"

if PATH="$tmp/bin:$PATH" \
    MOCK_DOCKER_LOG="$tmp/docker.log" MOCK_ADB_LOG="$tmp/adb.log" \
    MOCK_SCRCPY_LOG="$tmp/scrcpy.log" MOCK_ASSERT_LOG="$tmp/assert-fail.log" MOCK_FAIL_POST=1 \
    ROYD_DOCKER_COMMAND=docker ROYD_ADB_COMMAND=adb ROYD_SCRCPY_COMMAND=scrcpy \
    ROYD_SCRCPY_WAIT_RUNNER="$tmp/bin/pass" ROYD_SCRCPY_HEALTH_RUNNER="$tmp/bin/pass" \
    ROYD_SCRCPY_ASSERT_RUNNER="$tmp/bin/assert" \
    ROYD_SCRCPY_DURATION=1 ROYD_SCRCPY_MINIMUM_BYTES=1024 \
    ROYD_SCRCPY_OUTPUT_DIR="$tmp/failed-evidence" \
    "$script_dir/scrcpy-stability-test.sh" royd:test >"$tmp/error" 2>&1; then
  printf '%s\n' 'error: scrcpy stability test accepted a post-workload runtime failure' >&2
  exit 1
fi
grep -Fq 'post-workload runtime assertions failed' "$tmp/error"
grep -Fqx 'RESULT_STATUS=fail' "$tmp/failed-evidence/manifest.env"
grep -Fqx 'POST_RUNTIME_STATUS=fail' "$tmp/failed-evidence/manifest.env"
grep -Fq 'mock post-workload runtime failure' "$tmp/failed-evidence/post-runtime.log"
[ "$(wc -l <"$tmp/assert-fail.log")" -eq 2 ]
for file in scrcpy.mp4 scrcpy.log workload.log container.log container-inspect.json; do
  [ -f "$tmp/failed-evidence/$file" ]
done

if PATH="$tmp/bin:$PATH" ROYD_SCRCPY_DURATION=0 \
    ROYD_SCRCPY_OUTPUT_DIR="$tmp/invalid" \
    "$script_dir/scrcpy-stability-test.sh" royd:test >/dev/null 2>&1; then
  printf '%s\n' 'error: scrcpy stability test accepted a zero duration' >&2
  exit 1
fi

printf '%s\n' 'scrcpy stability contract test passed'
