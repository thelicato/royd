#!/bin/sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
tmp=$(mktemp -d)
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT INT TERM
cat > "$tmp/adb" <<'MOCK'
#!/bin/sh
set -eu
printf '%s\n' "$*" >> "$MOCK_ADB_LOG"
case "$*" in
  'connect 127.0.0.1:5555') printf '%s\n' 'connected to 127.0.0.1:5555' ;;
  '-s 127.0.0.1:5555 get-state') printf '%s\n' device ;;
  '-s 127.0.0.1:5555 shell getprop sys.boot_completed') printf '%s\n' 1 ;;
  '-s 127.0.0.1:5555 shell getprop init.svc.adbd') printf '%s\n' running ;;
  '-s 127.0.0.1:5555 logcat -d -t 1') printf '%s\n' '09-20 12:00:00.000 I royd: ready' ;;
  *) printf 'unexpected adb command: %s\n' "$*" >&2; exit 1 ;;
esac
MOCK
chmod +x "$tmp/adb"
: > "$tmp/adb.log"
PATH="$tmp:$PATH" MOCK_ADB_LOG="$tmp/adb.log" "$script_dir/adb-check.sh" >/dev/null
[ "$(wc -l < "$tmp/adb.log" | tr -d ' ')" = 5 ]
grep -Fqx 'connect 127.0.0.1:5555' "$tmp/adb.log"
grep -Fqx -- '-s 127.0.0.1:5555 logcat -d -t 1' "$tmp/adb.log"
printf '%s\n' 'ADB contract test passed'
