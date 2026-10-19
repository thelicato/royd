#!/bin/sh
# Internal workload for network-dns-test.sh's newly owned disposable container only.
set -eu
container=${1:?container required}
output=${2:?evidence directory required}
gateway=${3:?OCI gateway required}
url=${4:?baseline nonce URL required}
recovery_url=${5:?fresh recovery nonce URL required}
case "$container" in royd-network-dns-*) ;; *) exit 2 ;; esac
[ "$(docker inspect --format '{{index .Config.Labels "org.royd.test"}} {{index .Config.Labels "org.royd.test.owner"}}' "$container")" = "network-dns $container" ]
restore_needed=0
restore_link() {
  docker exec "$container" timeout 10 sh -c '
    set -eu
    ip link set dev eth0 up
    if ! ip -4 route show table main default | grep -Fxq "default via $1 dev eth0"; then
      ip -4 route add default via "$1" dev eth0
    fi
  ' sh "$gateway" >>"$output/link-restore.log" 2>&1
}
finish() {
  status=$?
  trap - EXIT HUP INT TERM
  if [ "$restore_needed" = 1 ]; then restore_link || status=1; fi
  exit "$status"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM
runtime_identity() {
  docker inspect --format '{{.Id}} {{.State.StartedAt}} {{.State.Running}} {{.RestartCount}} {{.State.OOMKilled}}' "$container"
}
runtime_identity >"$output/runtime-before.txt"
grep -Eq '^[a-f0-9]{64} [^ ]+ true 0 false$' "$output/runtime-before.txt"
docker exec "$container" input keyevent KEYCODE_WAKEUP
docker exec "$container" wm dismiss-keyguard
docker exec "$container" timeout 30 am start -W -n org.royd.networkprobe/.RecoveryProbe \
  --es url "$url" --es recovery_url "$recovery_url" >"$output/launch.log" 2>&1
grep -Fxq 'Status: ok' "$output/launch.log"
grep -Fxq 'Activity: org.royd.networkprobe/.RecoveryProbe' "$output/launch.log"
app_pid=$(docker exec "$container" pidof org.royd.networkprobe)
case "$app_pid" in ''|*[!0-9]*) exit 1 ;; esac
app_uid=$(docker exec "$container" stat -c %u "/proc/$app_pid")
case "$app_uid" in ''|*[!0-9]*) exit 1 ;; esac
[ "$app_uid" -ge 10000 ]
printf 'APP_PID=%s\nAPP_UID=%s\nURL=%s\nRECOVERY_URL=%s\n' "$app_pid" "$app_uid" "$url" "$recovery_url" >"$output/application.env"
for phase in baseline lost recovered; do
  result_file=/data/user/0/org.royd.networkprobe/files/$phase.json
  attempt=0
  until docker exec "$container" timeout 5 test -s "$result_file"; do
    attempt=$((attempt + 1)); [ "$attempt" -lt 45 ]; sleep 1
  done
  docker exec "$container" cat "$result_file" >"$output/$phase.json"
  [ "$app_uid" = "$(docker exec "$container" stat -c %u "$result_file")" ]
  [ "$app_pid" = "$(docker exec "$container" pidof org.royd.networkprobe)" ]
  [ "$app_uid" = "$(docker exec "$container" stat -c %u "/proc/$app_pid")" ]
  runtime_identity >"$output/runtime-$phase.txt"
  cmp -s "$output/runtime-before.txt" "$output/runtime-$phase.txt"
  docker exec "$container" timeout 15 dumpsys connectivity >"$output/connectivity-$phase.log" 2>&1
  docker exec "$container" sh -c 'ip -o -4 addr show dev eth0; ip -4 route show table main; ip link show dev eth0; cat /etc/resolv.conf' >"$output/oci-$phase.log"
  case "$phase" in
    baseline)
      # The test acts as the OCI owner, never as Android's network publisher.
      restore_needed=1
      docker exec "$container" timeout 10 ip link set dev eth0 down >"$output/link-down.log" 2>&1 ;;
    lost)
      grep -Fxq 'Active default network: none' "$output/connectivity-lost.log"
      restore_link
      restore_needed=0 ;;
  esac
done
docker exec "$container" logcat -d -s RoydNetworkRecovery:I '*:S' >"$output/application.log" 2>&1
# A normal input wake just before capture avoids changing the display timeout.
docker exec "$container" input keyevent KEYCODE_WAKEUP
docker exec "$container" wm dismiss-keyguard
docker exec "$container" screencap -p >"$output/application.png"
