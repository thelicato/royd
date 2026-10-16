#!/bin/sh
set -eu
container=${1:?usage: framework-restart-transition.sh CONTAINER TIMEOUT}
limit=${2:-180}
case "$limit" in ''|*[!0-9]*|0) exit 2 ;; esac
docker exec "$container" timeout "$limit" sh -c '
  # royd-framework-restart-transition
  set -eu
  single_pid() {
    case "$1" in ""|0|*[!0-9]*) return 1 ;; esac
  }
  [ "$(getprop ro.build.version.sdk)" = 35 ]
  [ "$(getprop sys.boot_completed)" = 1 ]
  [ "$(getprop sys.royd.framework_ready)" = 1 ]
  old_zygote=$(pidof zygote64)
  old_system=$(pidof system_server)
  single_pid "$old_zygote"
  single_pid "$old_system"
  printf "phase\tboot_completed\tframework_ready\tzygote\tsystem_server\n"
  printf "before\t1\t1\t%s\t%s\n" "$old_zygote" "$old_system"
  setprop ctl.restart zygote
  reset=0
  while :; do
    boot=$(getprop sys.boot_completed)
    ready=$(getprop sys.royd.framework_ready)
    zygote=$(pidof zygote64 || true)
    system=$(pidof system_server || true)
    printf "poll\t%s\t%s\t%s\t%s\n" "$boot" "$ready" "${zygote:--}" "${system:--}"
    # Never reset either property from the test, or accept stale boot readiness.
    [ "$boot" = 1 ]
    case "$ready" in 0) reset=1 ;; 1) ;; *) exit 1 ;; esac
    if [ "$reset" = 1 ] && [ "$ready" = 1 ] &&
        single_pid "$zygote" && single_pid "$system" &&
        [ "$zygote" != "$old_zygote" ] && [ "$system" != "$old_system" ]; then
      printf "recovered\t%s\t%s\t%s\t%s\n" "$boot" "$ready" "$zygote" "$system"
      break
    fi
    sleep 0.2
  done
'
