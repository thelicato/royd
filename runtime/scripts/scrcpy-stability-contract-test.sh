#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
tmp=$(mktemp -d)
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT HUP INT TERM
mkdir -p "$tmp/bin"
MOCK_REAL_SHA256SUM=$(command -v sha256sum)
export MOCK_REAL_SHA256SUM

cat >"$tmp/bin/sha256sum" <<'MOCK'
#!/bin/sh
if [ "${MOCK_POST_RECORDING:-}" = hash-read ]; then
  printf '%064d  -\n' 0
  exit 1
fi
exec "$MOCK_REAL_SHA256SUM" "$@"
MOCK
chmod +x "$tmp/bin/sha256sum"

cat >"$tmp/bin/docker" <<'MOCK'
#!/bin/sh
set -eu
printf '%s\n' "$*" >>"$MOCK_DOCKER_LOG"
case "$*" in
  'image inspect --format {{.Id}} '*) printf '%s\n' sha256:scrcpy-image ;;
  'volume create --label org.royd.test.owner='*)
    printf '%s\n' "${4#org.royd.test.owner=}" >"$MOCK_DOCKER_LOG.owner"
    ;;
  'volume inspect --format '*) cat "$MOCK_DOCKER_LOG.owner" ;;
  'volume inspect '*) exit 1 ;;
  'create '*' sha256:scrcpy-image '*) printf '%s\n' mock-container ;;
  'start mock-container') exit 0 ;;
  'port mock-container 5555/tcp') printf '%s\n' '127.0.0.1:40123' ;;
  'inspect --format {{index .Config.Labels "org.royd.test.owner"}} '*)
    printf '%s mock-container sha256:scrcpy-image\n' "$(cat "$MOCK_DOCKER_LOG.owner")"
    ;;
  'inspect --format '*) printf '%s\n' 'health=healthy' ;;
  'inspect mock-container') printf '%s\n' '[{"State":{"Running":true}}]' ;;
  'inspect '*) [ "${MOCK_RESOURCE_EXISTS:-0}" = 1 ] ;;
  'logs --timestamps mock-container')
    printf '%s\n' '[royd] mock log'
    if [ "${MOCK_REPLACE_OWNER:-0}" = 1 ]; then
      printf '%s\n' replacement >"$MOCK_DOCKER_LOG.owner"
    fi
    [ "${MOCK_FAIL_CAPTURE:-0}" = 0 ]
    ;;
  'exec mock-container sh -c '*) printf '%s\n' 'ROYD_REPORT_DIRECTORY=unavailable' ;;
  'rm -f mock-container'|'volume rm '*) exit 0 ;;
  *) printf 'unexpected docker command: %s\n' "$*" >&2; exit 1 ;;
esac
MOCK
chmod +x "$tmp/bin/docker"

cat >"$tmp/bin/adb" <<'MOCK'
#!/bin/sh
set -eu
printf '%s\n' "$*" >>"$MOCK_ADB_LOG"
case "$*" in
  '-L localfilesystem:'*' server nodaemon')
    exec python3 -c '
import signal
import socket
import sys
with socket.socket(socket.AF_UNIX) as server:
    server.bind(sys.argv[1])
    server.listen()
    signal.pause()
' "${2#localfilesystem:}"
    ;;
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

cat >"$tmp/bin/fail" <<'MOCK'
#!/bin/sh
printf '%s\n' 'mock prerequisite failure'
exit 1
MOCK
chmod +x "$tmp/bin/fail"

cat >"$tmp/bin/assert" <<'MOCK'
#!/bin/sh
set -eu
printf '%s\n' "$*" >>"$MOCK_ASSERT_LOG"
if [ "$(wc -l <"$MOCK_ASSERT_LOG")" -eq 2 ]; then
  case "${MOCK_POST_RECORDING:-}" in
    missing) rm "$ROYD_SCRCPY_OUTPUT_DIR/scrcpy.mp4" ;;
    truncated) : >"$ROYD_SCRCPY_OUTPUT_DIR/scrcpy.mp4" ;;
    missing-workload) rm "$ROYD_SCRCPY_OUTPUT_DIR/workload.log" ;;
    missing-scrcpy) rm "$ROYD_SCRCPY_OUTPUT_DIR/scrcpy.log" ;;
    adb-cleanup)
      socket=$(sed -n 's|^socket=localfilesystem:||p' "$ROYD_SCRCPY_OUTPUT_DIR/adb-owner.txt")
      : >"${socket%/server.sock}/keep-for-test"
      ;;
  esac
fi
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
grep -Fqx 'RECORDING_STATUS=pass' "$tmp/evidence/manifest.env"
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
grep -Fqx 'port mock-container 5555/tcp' "$tmp/docker.log"
grep -Fqx 'rm -f mock-container' "$tmp/docker.log"
grep -Fq 'connect 127.0.0.1:40123' "$tmp/adb.log"
grep -Eq -- '^-L localfilesystem:/tmp/royd-scrcpy-adb\.[^/]+/server.sock server nodaemon$' "$tmp/adb.log"
! grep -Eq '(^| )(kill-server|disconnect)( |$)' "$tmp/adb.log"

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

for failure in boot capture owner; do
  wait_runner="$tmp/bin/pass"
  fail_capture=0
  replace_owner=0
  case "$failure" in
    boot) wait_runner="$tmp/bin/fail" ;;
    capture) fail_capture=1 ;;
    owner) replace_owner=1 ;;
  esac
  if PATH="$tmp/bin:$PATH" \
      MOCK_DOCKER_LOG="$tmp/docker-$failure.log" MOCK_ADB_LOG="$tmp/adb.log" \
      MOCK_SCRCPY_LOG="$tmp/scrcpy.log" MOCK_FAIL_CAPTURE="$fail_capture" \
      MOCK_REPLACE_OWNER="$replace_owner" \
      MOCK_ASSERT_LOG="$tmp/assert-$failure.log" \
      ROYD_SCRCPY_WAIT_RUNNER="$wait_runner" ROYD_SCRCPY_HEALTH_RUNNER="$tmp/bin/pass" \
      ROYD_SCRCPY_ASSERT_RUNNER="$tmp/bin/assert" \
      ROYD_SCRCPY_DURATION=1 ROYD_SCRCPY_MINIMUM_BYTES=1024 \
      ROYD_SCRCPY_OUTPUT_DIR="$tmp/$failure-evidence" \
      "$script_dir/scrcpy-stability-test.sh" royd:test >/dev/null 2>&1; then
    printf 'error: scrcpy stability test accepted a %s failure\n' "$failure" >&2
    exit 1
  fi
  grep -Fqx 'RESULT_STATUS=fail' "$tmp/$failure-evidence/manifest.env"
  [ -f "$tmp/$failure-evidence/container-inspect.json" ]
done
grep -Fqx 'BOOT_STATUS=fail' "$tmp/boot-evidence/manifest.env"
grep -Fqx 'CONTAINER_EVIDENCE_STATUS=pass' "$tmp/boot-evidence/manifest.env"
grep -Fqx 'rm -f mock-container' "$tmp/docker-boot.log"
grep -Fqx 'CONTAINER_EVIDENCE_STATUS=fail' "$tmp/capture-evidence/manifest.env"
! grep -Eq '^(rm |volume rm )' "$tmp/docker-capture.log"
grep -Fqx 'CLEANUP_STATUS=fail' "$tmp/owner-evidence/manifest.env"
! grep -Eq '^(rm |volume rm )' "$tmp/docker-owner.log"

for recording in missing truncated missing-workload missing-scrcpy hash-read; do
  if PATH="$tmp/bin:$PATH" \
      MOCK_DOCKER_LOG="$tmp/docker-recording-$recording.log" MOCK_ADB_LOG="$tmp/adb.log" \
      MOCK_SCRCPY_LOG="$tmp/scrcpy.log" MOCK_ASSERT_LOG="$tmp/assert-recording-$recording.log" \
      MOCK_POST_RECORDING="$recording" \
      ROYD_SCRCPY_WAIT_RUNNER="$tmp/bin/pass" ROYD_SCRCPY_HEALTH_RUNNER="$tmp/bin/pass" \
      ROYD_SCRCPY_ASSERT_RUNNER="$tmp/bin/assert" \
      ROYD_SCRCPY_DURATION=1 ROYD_SCRCPY_MINIMUM_BYTES=1024 \
      ROYD_SCRCPY_OUTPUT_DIR="$tmp/recording-$recording" \
      "$script_dir/scrcpy-stability-test.sh" royd:test >"$tmp/recording-error" 2>&1; then
    printf 'error: scrcpy accepted a %s recording after post-workload checks\n' "$recording" >&2
    exit 1
  fi
  grep -Fqx 'RESULT_STATUS=fail' "$tmp/recording-$recording/manifest.env"
  grep -Fqx 'CONTAINER_EVIDENCE_STATUS=pass' "$tmp/recording-$recording/manifest.env"
  grep -Fqx 'RECORDING_STATUS=fail' "$tmp/recording-$recording/manifest.env"
  [ -f "$tmp/recording-$recording/container-inspect.json" ]
  ! grep -Eq '^(rm |volume rm )' "$tmp/docker-recording-$recording.log"
  if [ "$recording" = hash-read ]; then
    grep -Fqx 'RECORDING_SHA256=unavailable' "$tmp/recording-$recording/manifest.env"
  fi
done

if PATH="$tmp/bin:$PATH" \
    MOCK_DOCKER_LOG="$tmp/docker-adb-cleanup.log" MOCK_ADB_LOG="$tmp/adb.log" \
    MOCK_SCRCPY_LOG="$tmp/scrcpy.log" MOCK_ASSERT_LOG="$tmp/assert-adb-cleanup.log" \
    MOCK_POST_RECORDING=adb-cleanup \
    ROYD_SCRCPY_WAIT_RUNNER="$tmp/bin/pass" ROYD_SCRCPY_HEALTH_RUNNER="$tmp/bin/pass" \
    ROYD_SCRCPY_ASSERT_RUNNER="$tmp/bin/assert" \
    ROYD_SCRCPY_DURATION=1 ROYD_SCRCPY_MINIMUM_BYTES=1024 \
    ROYD_SCRCPY_OUTPUT_DIR="$tmp/adb-cleanup" \
    "$script_dir/scrcpy-stability-test.sh" royd:test >"$tmp/adb-cleanup-error" 2>&1; then
  printf '%s\n' 'error: scrcpy accepted failed private ADB cleanup' >&2
  exit 1
fi
grep -Fqx 'RESULT_STATUS=fail' "$tmp/adb-cleanup/manifest.env"
grep -Fqx 'CLEANUP_STATUS=fail' "$tmp/adb-cleanup/manifest.env"
socket=$(sed -n 's|^socket=localfilesystem:||p' "$tmp/adb-cleanup/adb-owner.txt")
adb_dir=${socket%/server.sock}
case "$adb_dir" in /tmp/royd-scrcpy-adb.????????) ;; *) exit 1 ;; esac
rm -- "$adb_dir/keep-for-test"
rmdir -- "$adb_dir"

if PATH="$tmp/bin:$PATH" MOCK_DOCKER_LOG="$tmp/docker-existing.log" MOCK_RESOURCE_EXISTS=1 \
    ROYD_SCRCPY_OUTPUT_DIR="$tmp/existing-resource" \
    "$script_dir/scrcpy-stability-test.sh" royd:test >"$tmp/existing-error" 2>&1; then
  printf '%s\n' 'error: scrcpy stability test accepted an existing Docker resource' >&2
  exit 1
fi
grep -Fq 'scrcpy resource already exists' "$tmp/existing-error"
[ ! -e "$tmp/existing-resource" ]
! grep -Eq '^(rm |volume rm |create |volume create )' "$tmp/docker-existing.log"

if PATH="$tmp/bin:$PATH" ROYD_SCRCPY_DURATION=0 \
    ROYD_SCRCPY_OUTPUT_DIR="$tmp/invalid" \
    "$script_dir/scrcpy-stability-test.sh" royd:test >/dev/null 2>&1; then
  printf '%s\n' 'error: scrcpy stability test accepted a zero duration' >&2
  exit 1
fi

printf '%s\n' 'scrcpy stability contract test passed'
