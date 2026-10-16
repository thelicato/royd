#!/bin/sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir "$tmp/bin"
cat >"$tmp/bin/docker" <<'MOCK'
#!/bin/sh
set -eu
[ "$1" = exec ] && [ "$2" = framework-contract ]
[ "$3" = timeout ] && [ "$4" = 5 ] && [ "$5" = sh ] && [ "$6" = -c ]
sh -c '. "$MOCK_ENV"; eval "$1"' sh "$7"
MOCK
chmod +x "$tmp/bin/docker"
cat >"$tmp/android.sh" <<'MOCK'
getprop() {
  step=$(cat "$MOCK_STATE/step")
  case "$1" in
    ro.build.version.sdk)
      if [ "$MOCK_CASE" = wrong_sdk ]; then printf '%s\n' 34; else printf '%s\n' 35; fi ;;
    sys.boot_completed)
      if [ "$step" -gt 0 ]; then
        step=$((step + 1))
        printf '%s\n' "$step" >"$MOCK_STATE/step"
      fi
      case "$MOCK_CASE:$step" in
        not_booted:0|boot_cleared:2) printf '%s\n' 0 ;;
        getprop_failure:2) return 1 ;;
        *) printf '%s\n' 1 ;;
      esac
      ;;
    sys.royd.framework_ready)
      case "$MOCK_CASE:$step" in
        not_ready:0|*:2) [ "$MOCK_CASE" != no_reset ] || { printf '%s\n' 1; return; }
          if [ "$MOCK_CASE" = invalid_ready ]; then printf '%s\n' invalid; else printf '%s\n' 0; fi ;;
        no_recovery:*[1-9]*) printf '%s\n' 0 ;;
        *) printf '%s\n' 1 ;;
      esac
      ;;
    *) return 99 ;;
  esac
}
pidof() {
  step=$(cat "$MOCK_STATE/step")
  case "$1:$step:$MOCK_CASE" in
    zygote64:0:missing_old) return 1 ;;
    system_server:0:multiple_old) printf '%s\n' '101 102' ;;
    zygote64:0:*|zygote64:*:old_zygote) printf '%s\n' 100 ;;
    system_server:0:*|system_server:*:old_system) printf '%s\n' 101 ;;
    zygote64:*:missing_new) return 1 ;;
    system_server:*:multiple_new) printf '%s\n' '200 201' ;;
    zygote64:*) printf '%s\n' 200 ;;
    system_server:2:*) return 1 ;;
    system_server:*) printf '%s\n' 201 ;;
    *) return 99 ;;
  esac
}
setprop() {
  [ "$*" = 'ctl.restart zygote' ]
  printf '%s\n' "$*" >>"$MOCK_STATE/writes"
  [ "$MOCK_CASE" != request_failure ] || return 1
  printf '%s\n' 1 >"$MOCK_STATE/step"
}
sleep() {
  [ "$1" = 0.2 ]
  step=$(cat "$MOCK_STATE/step")
  # Model the outer timeout without real sleeps in the negative contract cases.
  if [ "$step" -ge 4 ]; then exit 124; fi
}
MOCK
for mode in good wrong_sdk not_booted not_ready missing_old multiple_old request_failure \
    boot_cleared getprop_failure invalid_ready no_reset no_recovery old_zygote old_system \
    missing_new multiple_new; do
  state="$tmp/$mode"
  mkdir "$state"
  printf '%s\n' 0 >"$state/step"
  status=0
  PATH="$tmp/bin:$PATH" MOCK_ENV="$tmp/android.sh" MOCK_STATE="$state" MOCK_CASE="$mode" \
    "$script_dir/framework-restart-transition.sh" framework-contract 5 >"$state/readiness.tsv" 2>&1 || status=$?
  if [ "$mode" = good ]; then
    [ "$status" -eq 0 ]
    grep -q '^recovered' "$state/readiness.tsv"
    grep -Fxq 'ctl.restart zygote' "$state/writes"
    [ "$(wc -l <"$state/writes")" -eq 1 ]
  elif [ "$status" -eq 0 ]; then
    printf 'error: framework restart transition accepted %s\n' "$mode" >&2
    exit 1
  fi
done
printf '%s\n' 'Android 15 framework restart transition contract test passed'
