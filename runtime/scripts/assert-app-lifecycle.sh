#!/bin/sh
set -eu

container=${1:-royd}
docker exec "$container" sh -c '
  # royd-runtime-app-lifecycle-test
  set -eu
  [ "$(getprop ro.build.version.sdk)" = 35 ]
  before=$(pidof system_server)
  case "$before" in ""|*[!0-9]*) exit 1 ;; esac
  trap '\''timeout 10 am force-stop org.chromium.webview_shell >/dev/null 2>&1 || true; input keyevent KEYCODE_HOME >/dev/null 2>&1 || true'\'' EXIT INT TERM

  launch_webview() {
    launch=$(timeout 30 am start -W -n org.chromium.webview_shell/.WebViewBrowserActivity)
    printf "%s\n" "$launch" | grep -Fxq "Status: ok"
    printf "%s\n" "$launch" | grep -Fxq \
      "Activity: org.chromium.webview_shell/.WebViewBrowserActivity"
    sleep 2
  }
  assert_uid_thawed_or_removed() {
    group=/sys/fs/cgroup/royd/uid_$uid
    if state=$(cat "$group/cgroup.freeze" 2>/dev/null); then
      [ "$state" = 0 ]
    else
      # Process-group cleanup may remove the UID root, but not leave it unreadable.
      ! test -d "$group"
    fi
  }

  launch_webview
  first=$(pidof org.chromium.webview_shell)
  case "$first" in ""|*[!0-9]*) exit 1 ;; esac
  uid=$(stat -c %u "/proc/$first")
  case "$uid" in ""|*[!0-9]*) exit 1 ;; esac
  [ "$uid" -ge 10000 ]
  timeout 30 am force-stop org.chromium.webview_shell
  if pidof org.chromium.webview_shell >/dev/null; then
    printf "%s\n" "error: force-stop left the application alive" >&2
    exit 1
  fi
  assert_uid_thawed_or_removed

  launch_webview
  second=$(pidof org.chromium.webview_shell)
  case "$second" in ""|*[!0-9]*) exit 1 ;; esac
  [ "$first" != "$second" ]
  [ "$(stat -c %u "/proc/$second")" = "$uid" ]
  assert_uid_thawed_or_removed
  [ "$before" = "$(pidof system_server)" ]
  printf "Application lifecycle passed: old_pid=%s new_pid=%s uid=%s\n" "$first" "$second" "$uid"
' || {
  printf 'error: Android 15 application force-stop/relaunch contract failed in %s\n' "$container" >&2
  exit 1
}
