#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
watchdog="$root/android/royd/vendor/royd/bin/royd-boot-watchdog"
diag="$root/android/royd/vendor/royd/bin/royd-diagnostics"
rc="$root/android/royd/vendor/royd/init.royd.rc"
mk="$root/android/royd/vendor/royd/royd.mk"
sh -n "$watchdog" "$diag"
grep -Fq 'service royd-boot-watchdog /vendor/bin/royd-boot-watchdog' "$rc"
grep -Fq 'on property:init.svc.zygote=running' "$rc"
grep -Fq 'royd-diagnostics' "$mk"
grep -Fq 'royd-boot-watchdog' "$mk"
grep -Fq 'ro.vendor.royd.boot_watchdog_timeout=120' "$mk"
grep -Fq 'sys.boot_completed' "$watchdog"
grep -Fq 'recent-logcat' "$diag"
grep -Fq '/proc/pressure/memory' "$diag"
grep -Fq 'service list' "$diag"
! grep -Eq '\b(reboot|poweroff|kill -9)\b' "$watchdog"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM
mkdir -p "$tmp/bin"
cat > "$tmp/bin/getprop" <<'EOS'
#!/bin/sh
case "$1" in
  sys.boot_completed) printf '%s\n' "${MOCK_BOOT_COMPLETED:-0}" ;;
  *) printf '\n' ;;
esac
EOS
cat > "$tmp/bin/setprop" <<'EOS'
#!/bin/sh
printf '%s=%s\n' "$1" "$2" >> "$MOCK_SETPROP_LOG"
EOS
cat > "$tmp/bin/sleep" <<'EOS'
#!/bin/sh
exit 0
EOS
cat > "$tmp/diagnostics" <<'EOS'
#!/bin/sh
printf '%s\n' diagnostics >> "$MOCK_DIAGNOSTICS_LOG"
EOS
chmod +x "$tmp/bin/"* "$tmp/diagnostics"

: > "$tmp/setprop.log"; : > "$tmp/diag.log"; : > "$tmp/stdout.log"
PATH="$tmp/bin:$PATH" MOCK_BOOT_COMPLETED=1 MOCK_SETPROP_LOG="$tmp/setprop.log" MOCK_DIAGNOSTICS_LOG="$tmp/diag.log" ROYD_DIAGNOSTICS_STDOUT="$tmp/stdout.log" ROYD_DIAGNOSTICS_BIN="$tmp/diagnostics" ROYD_BOOT_WATCHDOG_TIMEOUT=1 ROYD_BOOT_WATCHDOG_INTERVAL=1 sh "$watchdog"
grep -Fq 'vendor.royd.boot_watchdog=complete' "$tmp/setprop.log"
[ ! -s "$tmp/diag.log" ]

: > "$tmp/setprop.log"; : > "$tmp/diag.log"; : > "$tmp/stdout.log"
PATH="$tmp/bin:$PATH" MOCK_BOOT_COMPLETED=0 MOCK_SETPROP_LOG="$tmp/setprop.log" MOCK_DIAGNOSTICS_LOG="$tmp/diag.log" ROYD_DIAGNOSTICS_STDOUT="$tmp/stdout.log" ROYD_DIAGNOSTICS_BIN="$tmp/diagnostics" ROYD_BOOT_WATCHDOG_TIMEOUT=2 ROYD_BOOT_WATCHDOG_INTERVAL=1 sh "$watchdog"
grep -Fq 'vendor.royd.boot_watchdog=timeout' "$tmp/setprop.log"
[ "$(wc -l < "$tmp/diag.log" | tr -d ' ')" = 1 ]
grep -Fq 'timeout after 2s; collecting diagnostics' "$tmp/stdout.log"
printf '%s\n' 'boot diagnostics contract passed'
