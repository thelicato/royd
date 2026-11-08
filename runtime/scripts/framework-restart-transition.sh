#!/bin/sh
set -eu
container=${1:?usage: framework-restart-transition.sh CONTAINER TIMEOUT [zygote|netd]}
limit=${2:-180}
service=${3:-zygote}
case "$limit" in ''|*[!0-9]*|0) exit 2 ;; esac
case "$service" in zygote|netd) ;; *) exit 2 ;; esac
docker exec "$container" timeout "$limit" sh -c '
  # royd-framework-restart-transition
  set -eu
  service=$1
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
  old_netd=-
  if [ "$service" = netd ]; then old_netd=$(pidof netd); single_pid "$old_netd"; fi
  printf "phase\tboot_completed\tframework_ready\tzygote\tsystem_server"
  if [ "$service" = netd ]; then printf "\tnetd"; fi
  printf "\n"
  emit() {
    printf "%s\t%s\t%s\t%s\t%s" "$1" "$2" "$3" "$4" "$5"
    if [ "$service" = netd ]; then printf "\t%s" "$6"; fi
    printf "\n"
  }
  emit before 1 1 "$old_zygote" "$old_system" "$old_netd"
  setprop ctl.restart "$service"
  reset=0
  while :; do
    boot=$(getprop sys.boot_completed)
    ready=$(getprop sys.royd.framework_ready)
    zygote=$(pidof zygote64 || true)
    system=$(pidof system_server || true)
    netd=-
    daemon_ready=1
    if [ "$service" = netd ]; then
      netd=$(pidof netd || true)
      daemon_ready=0
      if single_pid "$netd" && [ "$netd" != "$old_netd" ]; then daemon_ready=1; fi
    fi
    emit poll "$boot" "$ready" "${zygote:--}" "${system:--}" "${netd:--}"
    # Never reset either property from the test, or accept stale boot readiness.
    [ "$boot" = 1 ]
    case "$ready" in 0) reset=1 ;; 1) ;; *) exit 1 ;; esac
    if [ "$reset" = 1 ] && [ "$ready" = 1 ] &&
        single_pid "$zygote" && single_pid "$system" &&
        [ "$zygote" != "$old_zygote" ] && [ "$system" != "$old_system" ] &&
        [ "$daemon_ready" = 1 ]; then
      emit recovered "$boot" "$ready" "$zygote" "$system" "$netd"
      break
    fi
    sleep 0.2
  done
' sh "$service"
