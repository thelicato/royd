#!/bin/sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir -p "$tmp/bin"
cat >"$tmp/bin/docker" <<'MOCK'
#!/bin/sh
set -eu
[ "$1" = exec ] && [ "$2" = lifecycle-contract ]
shift 2
[ "$1" = sh ] && [ "$2" = -c ]
sh -c '. "$ROYD_LIFECYCLE_MOCK"; eval "$1"' sh "$3"
MOCK
chmod +x "$tmp/bin/docker"
cat >"$tmp/android-mocks.sh" <<'MOCK'
getprop() {
  [ "$1" = ro.build.version.sdk ]
  if [ "$MOCK_CASE" = wrong_sdk ]; then printf '%s\n' 34; else printf '%s\n' 35; fi
}
pidof() {
  case "$1" in
    system_server)
      if [ -e "$MOCK_STATE/system-read" ] && [ "$MOCK_CASE" = server_restart ]; then
        printf '%s\n' 501
      else
        : >"$MOCK_STATE/system-read"
        printf '%s\n' 500
      fi
      ;;
    org.chromium.webview_shell)
      phase=$(command cat "$MOCK_STATE/phase")
      case "$phase:$MOCK_CASE" in
        1:missing_pid) return 1 ;;
        1:multiple_pids) printf '%s\n' '101 102' ;;
        1:*) printf '%s\n' 101 ;;
        2:reuse_pid) printf '%s\n' 101 ;;
        2:*) printf '%s\n' 202 ;;
        *) return 1 ;;
      esac
      ;;
    *) return 99 ;;
  esac
}
am() {
  printf '%s\n' "$*" >>"$MOCK_STATE/am.log"
  case "$*" in
    'start -W -n org.chromium.webview_shell/.WebViewBrowserActivity')
      count=$(command cat "$MOCK_STATE/launches")
      count=$((count + 1))
      printf '%s\n' "$count" >"$MOCK_STATE/launches"
      printf '%s\n' "$count" >"$MOCK_STATE/phase"
      [ "$MOCK_CASE" != launch_failure ] || return 1
      if [ "$MOCK_CASE" = bad_status ]; then
        printf '%s\n' 'Error: Activity not started'
      elif [ "$MOCK_CASE" = wrong_activity ]; then
        printf '%s\n' 'Status: ok' 'Activity: other/.Activity'
      else
        printf '%s\n' 'Status: ok' 'Activity: org.chromium.webview_shell/.WebViewBrowserActivity'
      fi
      ;;
    'force-stop org.chromium.webview_shell')
      [ "$MOCK_CASE" != stop_failure ] || return 1
      [ "$MOCK_CASE" = lingering ] || printf '%s\n' 0 >"$MOCK_STATE/phase"
      ;;
    *) return 99 ;;
  esac
}
stat() {
  [ "$1" = -c ] && [ "$2" = %u ]
  case "$3" in /proc/101|/proc/202) ;; *) return 99 ;; esac
  case "$MOCK_CASE:$3" in
    malformed_uid:*) printf '%s\n' invalid ;;
    system_uid:*) printf '%s\n' 1000 ;;
    uid_changed:/proc/202) printf '%s\n' 10056 ;;
    *) printf '%s\n' 10055 ;;
  esac
}
cat() {
  [ "$1" = /sys/fs/cgroup/royd/uid_10055/cgroup.freeze ] || return 99
  case "$MOCK_CASE" in
    removed|unreadable) return 1 ;;
    frozen) printf '%s\n' 1 ;;
    malformed_freezer) printf '%s\n' invalid ;;
    *) printf '%s\n' 0 ;;
  esac
}
test() {
  [ "$1" = -d ] && [ "$2" = /sys/fs/cgroup/royd/uid_10055 ] || return 99
  [ "$MOCK_CASE" != removed ]
}
timeout() {
  case "$1" in 10|30) ;; *) return 99 ;; esac
  shift
  if [ "$MOCK_CASE" = launch_timeout ] && [ "$2" = start ]; then return 124; fi
  "$@"
}
sleep() { [ "$1" = 2 ]; }
input() { [ "$*" = 'keyevent KEYCODE_HOME' ]; }
MOCK

for mode in good removed wrong_sdk launch_failure bad_status wrong_activity missing_pid \
    multiple_pids malformed_uid system_uid stop_failure lingering frozen malformed_freezer \
    unreadable reuse_pid uid_changed server_restart launch_timeout; do
  state="$tmp/$mode"
  mkdir -p "$state"
  printf '%s\n' 0 >"$state/phase"
  printf '%s\n' 0 >"$state/launches"
  status=0
  PATH="$tmp/bin:$PATH" ROYD_LIFECYCLE_MOCK="$tmp/android-mocks.sh" \
    MOCK_STATE="$state" MOCK_CASE="$mode" \
    "$script_dir/assert-app-lifecycle.sh" lifecycle-contract >"$state/result.log" 2>&1 || status=$?
  case "$mode" in
    good|removed)
      [ "$status" -eq 0 ]
      grep -Fq 'Application lifecycle passed: old_pid=101 new_pid=202 uid=10055' "$state/result.log"
      [ "$(cat "$state/phase")" = 0 ]
      [ "$(cat "$state/launches")" = 2 ]
      [ "$(grep -c '^force-stop ' "$state/am.log")" = 2 ]
      ;;
    *)
      if [ "$status" -eq 0 ]; then
        printf 'error: app lifecycle assertion accepted %s\n' "$mode" >&2
        exit 1
      fi
      grep -Fq 'application force-stop/relaunch contract failed' "$state/result.log"
      ;;
  esac
done
printf '%s\n' 'Android 15 application lifecycle contract test passed'
