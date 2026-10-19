#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROYD_CONTAINER_EVIDENCE_SCRIPT="$script_dir/container-evidence.sh" \
  go test "$script_dir/../tests/container-evidence/template_test.go"
tmp=$(mktemp -d)
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT HUP INT TERM
mkdir -p "$tmp/bin"

cat > "$tmp/bin/docker" <<'MOCK'
#!/bin/sh
set -eu
case "$1" in
  inspect)
    shift
    if [ "${1:-}" = --format ]; then
      shift 2
      cat <<'STATE'
name=/mock-royd
id=abc123
image=sha256:image
status=exited
running=false
exit_code=1
oom_killed=false
error=
health=unhealthy
STATE
    else
      printf '%s\n' '[{"Id":"abc123","State":{"Status":"exited"}}]'
    fi
    ;;
  logs)
    [ "${2:-}" = --timestamps ] || exit 97
    printf '%s\n' '2026-09-20T18:00:00Z [royd] boot-watchdog: timeout after 120s; collecting diagnostics'
    printf '%s\n' '2026-09-20T18:00:00Z [royd] diagnostics: --- recent-logcat ---'
    ;;
  *) exit 98 ;;
esac
MOCK
chmod +x "$tmp/bin/docker"

PATH="$tmp/bin:$PATH" "$script_dir/container-evidence.sh" mock-royd "$tmp/evidence" > "$tmp/output"
grep -Fq '"Id":"abc123"' "$tmp/evidence/container-inspect.json"
grep -Fq 'status=exited' "$tmp/evidence/state.txt"
grep -Fxq 'health=unhealthy' "$tmp/evidence/state.txt"
grep -Fq 'boot-watchdog: timeout after 120s' "$tmp/evidence/container.log"
grep -Fq 'Captured Docker inspect and full timestamped logs' "$tmp/output"

cat > "$tmp/bin/docker" <<'MOCK'
#!/bin/sh
set -eu
case "$1" in
  inspect)
    [ "$MOCK_FAILURE" != missing ] || exit 1
    if [ "$MOCK_FAILURE" = inspect ]; then
      [ ! -e "$MOCK_COUNTER" ] || exit 1
      : >"$MOCK_COUNTER"
    fi
    if [ "${2:-}" = --format ]; then
      [ "$MOCK_FAILURE" != state ] || exit 1
      printf '%s\n' 'status=created' 'health=none'
    else
      printf '%s\n' '[{"State":{"Status":"created"}}]'
    fi
    exit 0
    ;;
  logs) [ "$MOCK_FAILURE" = empty-logs ] ;;
  *) exit 1 ;;
esac
MOCK
chmod +x "$tmp/bin/docker"
for failure in missing inspect state logs; do
  if PATH="$tmp/bin:$PATH" MOCK_FAILURE="$failure" MOCK_COUNTER="$tmp/$failure.count" \
      "$script_dir/container-evidence.sh" mock-royd "$tmp/$failure" >"$tmp/$failure.log" 2>&1; then
    printf 'error: container evidence unexpectedly accepted unavailable %s\n' "$failure" >&2
    exit 1
  fi
  ! grep -Fq 'Captured Docker inspect and full timestamped logs' "$tmp/$failure.log"
done
PATH="$tmp/bin:$PATH" MOCK_FAILURE=empty-logs \
  "$script_dir/container-evidence.sh" mock-royd "$tmp/empty" >"$tmp/empty.log"
grep -Fxq 'health=none' "$tmp/empty/state.txt"
test -f "$tmp/empty/container.log"
test ! -s "$tmp/empty/container.log"

printf '%s\n' 'Container evidence test passed'
