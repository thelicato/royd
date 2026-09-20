#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
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
grep -Fq 'boot-watchdog: timeout after 120s' "$tmp/evidence/container.log"
grep -Fq 'Captured Docker inspect and full timestamped logs' "$tmp/output"

cat > "$tmp/bin/docker" <<'MOCK'
#!/bin/sh
case "$1" in
  inspect)
    if [ "${2:-}" = --format ]; then printf '%s\n' 'status=running'; else printf '%s\n' '[{}]'; fi
    exit 0
    ;;
  logs) exit 1 ;;
  *) exit 1 ;;
esac
MOCK
chmod +x "$tmp/bin/docker"
if PATH="$tmp/bin:$PATH" "$script_dir/container-evidence.sh" mock-royd "$tmp/failing" >/dev/null 2>&1; then
  printf '%s\n' 'error: container evidence unexpectedly accepted unavailable Docker logs' >&2
  exit 1
fi

printf '%s\n' 'Container evidence test passed'
