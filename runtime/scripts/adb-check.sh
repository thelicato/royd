#!/bin/sh
set -eu
host=${ROYD_ADB_HOST:-127.0.0.1}
port=${ROYD_ADB_PORT:-5555}
serial=${ROYD_ADB_SERIAL:-$host:$port}
command -v adb >/dev/null 2>&1 || {
  printf '%s\n' 'error: adb is required for ADB validation' >&2
  exit 1
}
adb connect "$serial" >/dev/null
state=$(adb -s "$serial" get-state 2>/dev/null || true)
[ "$state" = device ] || {
  printf 'error: ADB device is not ready at %s\n' "$serial" >&2
  exit 1
}
boot=$(adb -s "$serial" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')
[ "$boot" = 1 ] || {
  printf 'error: Android has not completed boot at %s\n' "$serial" >&2
  exit 1
}
adbd=$(adb -s "$serial" shell getprop init.svc.adbd 2>/dev/null | tr -d '\r')
[ "$adbd" = running ] || {
  printf 'error: adbd is not running at %s\n' "$serial" >&2
  exit 1
}
adb -s "$serial" logcat -d -t 1 >/dev/null 2>&1 || {
  printf 'error: adb logcat failed at %s\n' "$serial" >&2
  exit 1
}
printf 'ADB checks passed: %s\n' "$serial"
