#!/bin/sh
# Internal workload, only for the DNS runner's newly labelled disposable container.
set -eu
container=${1:?container required}
output=${2:?evidence required}
gateway=${3:?DNS fixture required}
url=${4:?nonce URL required}
[ "$(docker inspect --format '{{index .Config.Labels "org.royd.test"}} {{index .Config.Labels "org.royd.test.owner"}}' "$container")" = "network-dns $container" ]
restore_needed=0
restore() {
  restore_status=0
  docker exec "$container" timeout 15 cmd connectivity set-package-networking-enabled true org.royd.networkprobe || restore_status=1
  docker exec "$container" timeout 15 cmd connectivity set-chain3-enabled false || restore_status=1
  docker exec "$container" timeout 15 cmd connectivity get-package-networking-enabled org.royd.networkprobe >"$output/restored-rule-check.log" || restore_status=1
  grep -Fxq org.royd.networkprobe:allow "$output/restored-rule-check.log" || restore_status=1
  docker exec "$container" timeout 15 cmd connectivity get-chain3-enabled >"$output/restored-chain-check.log" || restore_status=1
  grep -Fxq chain:disabled "$output/restored-chain-check.log" || restore_status=1
  return "$restore_status"
}
finish() {
  status=$?
  trap - EXIT HUP INT TERM
  if [ "$restore_needed" = 1 ]; then restore >>"$output/policy-cleanup.log" 2>&1 || status=1; fi
  exit "$status"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM
snapshot() {
  docker inspect --format '{{.Id}} {{.State.StartedAt}} {{.State.Running}} {{.RestartCount}} {{.State.OOMKilled}}' "$container"
}
snapshot >"$output/runtime-before.txt"
grep -Eq '^[a-f0-9]{64} [^ ]+ true 0 false$' "$output/runtime-before.txt"
docker cp "$output/build/control.apk" "$container:/data/local/tmp/royd-network-control.apk"
docker exec "$container" timeout 30 pm install -t /data/local/tmp/royd-network-control.apk >"$output/control-install.log" 2>&1
grep -Fxq Success "$output/control-install.log"
docker exec "$container" timeout 15 cmd connectivity get-chain3-enabled >"$output/chain-before.log"
grep -Fxq chain:disabled "$output/chain-before.log"
for package in org.royd.networkprobe org.royd.networkcontrol; do
  docker exec "$container" timeout 15 cmd connectivity get-package-networking-enabled "$package" >"$output/$package-before.log"
  grep -Fxq "$package:allow" "$output/$package-before.log"
done
for phase in baseline blocked restored; do
  case "$phase" in
    blocked)
      restore_needed=1
      docker exec "$container" timeout 15 cmd connectivity set-package-networking-enabled false org.royd.networkprobe >"$output/policy-deny.log" 2>&1
      docker exec "$container" timeout 15 cmd connectivity set-chain3-enabled true >>"$output/policy-deny.log" 2>&1 ;;
    restored) restore >"$output/policy-restore.log" 2>&1; restore_needed=0 ;;
  esac
  docker exec "$container" timeout 15 cmd connectivity get-chain3-enabled >"$output/chain-$phase.log"
  docker exec "$container" timeout 15 dumpsys connectivity trafficcontroller >"$output/bpf-$phase.log" 2>&1
  docker exec "$container" timeout 15 dumpsys connectivity >"$output/connectivity-$phase.log" 2>&1
  for role in target control; do
    package=org.royd.networkprobe
    component=$package/.NetworkProbe
    if [ "$role" = control ]; then package=org.royd.networkcontrol; component=$package/org.royd.networkprobe.NetworkProbe; fi
    name=$phase-$role
    docker exec "$container" timeout 15 cmd connectivity get-package-networking-enabled "$package" >"$output/rule-$name.log"
    docker exec "$container" timeout 15 am force-stop --user 0 "$package" >"$output/stop-$name.log" 2>&1
    status=0
    docker exec "$container" pidof "$package" >"$output/stopped-$name.txt" || status=$?
    [ "$status" -eq 1 ] && [ ! -s "$output/stopped-$name.txt" ]
    result_file=/data/user/0/$package/files/result.json
    # Only this newly installed test APK's generated private observation is replaced.
    docker exec "$container" rm -f "$result_file"
    docker exec "$container" input keyevent KEYCODE_WAKEUP
    docker exec "$container" wm dismiss-keyguard
    docker exec "$container" timeout 30 am start -W -n "$component" --es host royd-probe.test --es dns "$gateway" \
      --es url "$url?policy=$name" >"$output/launch-$name.log" 2>&1
    grep -Fxq 'Status: ok' "$output/launch-$name.log"
    grep -Fxq "Activity: $component" "$output/launch-$name.log"
    attempt=0
    until docker exec "$container" timeout 5 test -s "$result_file"; do
      attempt=$((attempt+1)); [ "$attempt" -lt 90 ]; sleep 1
    done
    docker exec "$container" cat "$result_file" >"$output/$name.json"
    pid=$(docker exec "$container" pidof "$package")
    case "$pid" in ''|*[!0-9]*) exit 1 ;; esac
    uid=$(docker exec "$container" stat -c %u "/proc/$pid")
    case "$uid" in ''|*[!0-9]*) exit 1 ;; esac
    [ "$uid" -ge 10000 ]
    [ "$uid" = "$(docker exec "$container" stat -c %u "$result_file")" ]
    printf '%s %s\n' "$pid" "$uid" >"$output/$name.identity"
    docker exec "$container" cat "/proc/$pid/cgroup" >"$output/cgroup-$name.log"
    snapshot >"$output/runtime-$name.txt"
    cmp -s "$output/runtime-before.txt" "$output/runtime-$name.txt"
  done
done
docker exec "$container" logcat -d -s RoydNetworkProbe:I '*:S' >"$output/application.log" 2>&1
docker exec "$container" input keyevent KEYCODE_WAKEUP
docker exec "$container" wm dismiss-keyguard
docker exec "$container" screencap -p >"$output/application.png"
