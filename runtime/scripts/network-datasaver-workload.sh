#!/bin/sh
# Activation and restoration only, not background-traffic enforcement qualification.
set -eu
container=${1:?container required}
output=${2:?new DNS evidence directory required}
gateway=${3:?controlled answer required}
resolver=${4:?configured resolver required}
url=${5:?controlled nonce URL required}
uid_before=${6:?observed ordinary UID required}
[ "$(docker inspect --format '{{index .Config.Labels "org.royd.test"}} {{index .Config.Labels "org.royd.test.owner"}}' "$container")" = "network-dns $container" ]
docker inspect --format '{{.Id}} {{.State.StartedAt}} {{.State.Running}} {{.RestartCount}} {{.State.OOMKilled}}' "$container" >"$output/runtime-before.txt"
grep -Eq '^[a-f0-9]{64} [^ ]+ true 0 false$' "$output/runtime-before.txt"
command_status=not-tested
activation=not-tested
restoration=not-tested
app=not-tested
restore_needed=0
restore() {
  restore_status=0
  docker exec "$container" timeout 15 cmd netpolicy set restrict-background false >"$output/datasaver-disable.log" 2>&1 || restore_status=1
  docker exec "$container" timeout 15 cmd netpolicy get restrict-background >"$output/datasaver-restored.log" 2>&1 || restore_status=1
  docker exec "$container" timeout 15 dumpsys connectivity trafficcontroller >"$output/datasaver-restored-bpf.log" 2>&1 || restore_status=1
  grep -Fxq 'Restrict background status: disabled' "$output/datasaver-restored.log" || restore_status=1
  grep -Eq '^[[:space:]]*sDataSaverEnabledMap: false$' "$output/datasaver-restored-bpf.log" || restore_status=1
  restoration=fail
  if [ "$restore_status" -eq 0 ]; then restoration=pass; fi
  return "$restore_status"
}
finish() {
  status=$?
  trap - EXIT HUP INT TERM
  if [ "$restore_needed" = 1 ]; then restore || status=1; fi
  cat >"$output/datasaver-assessment.env" <<MANIFEST
DATASAVER_COMMAND_STATUS=$command_status
DATASAVER_ACTIVATION_STATUS=$activation
DATASAVER_RESTORATION_STATUS=$restoration
DATASAVER_APP_CONTROL_STATUS=$app
DATASAVER_ENFORCEMENT_STATUS=not-tested
MANIFEST
  exit "$status"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM
docker exec "$container" timeout 15 cmd netpolicy get restrict-background >"$output/datasaver-before.log"
grep -Fxq 'Restrict background status: disabled' "$output/datasaver-before.log"
docker exec "$container" timeout 15 dumpsys connectivity trafficcontroller >"$output/datasaver-before-bpf.log" 2>&1
grep -Eq '^[[:space:]]*sDataSaverEnabledMap: false$' "$output/datasaver-before-bpf.log"
docker exec "$container" timeout 15 dumpsys netpolicy >"$output/datasaver-before-netpolicy.log" 2>&1
restore_needed=1
command_status=pass
command_exit=0
docker exec "$container" timeout 15 cmd netpolicy set restrict-background true >"$output/datasaver-enable.log" 2>&1 || command_exit=$?
printf 'SET_COMMAND_EXIT_STATUS=%s\n' "$command_exit" >"$output/datasaver-command.env"
if [ "$command_exit" -ne 0 ]; then command_status=fail; fi
# The Binder-facing shell command can succeed even if the service rolls back.
docker exec "$container" timeout 15 cmd netpolicy get restrict-background >"$output/datasaver-requested.log"
docker exec "$container" timeout 15 dumpsys connectivity trafficcontroller >"$output/datasaver-requested-bpf.log" 2>&1
docker exec "$container" timeout 15 dumpsys netpolicy >"$output/datasaver-requested-netpolicy.log" 2>&1
docker exec "$container" timeout 15 dumpsys network_management >"$output/datasaver-network-management.log" 2>&1
activation=fail
if [ "$command_status" = pass ] && grep -Fxq 'Restrict background status: enabled' "$output/datasaver-requested.log" \
    && grep -Eq '^[[:space:]]*sDataSaverEnabledMap: true$' "$output/datasaver-requested-bpf.log"; then activation=pass; fi
restore
restore_needed=0
docker exec "$container" timeout 15 am force-stop --user 0 org.royd.networkprobe >"$output/datasaver-stop.log" 2>&1
status=0
docker exec "$container" pidof org.royd.networkprobe >"$output/datasaver-stopped-pid.txt" || status=$?
[ "$status" -eq 1 ] && [ ! -s "$output/datasaver-stopped-pid.txt" ]
result_file=/data/user/0/org.royd.networkprobe/files/result.json
# The baseline observation has already been retained outside this owned test APK.
docker exec "$container" rm -f "$result_file"
docker exec "$container" input keyevent KEYCODE_WAKEUP
docker exec "$container" wm dismiss-keyguard
docker exec "$container" timeout 30 am start -W -n org.royd.networkprobe/.NetworkProbe \
  --es host royd-probe.test --es dns "$gateway" --es url "$url?datasaver=restored" >"$output/datasaver-launch.log" 2>&1
grep -Fxq 'Status: ok' "$output/datasaver-launch.log"
grep -Fxq 'Activity: org.royd.networkprobe/.NetworkProbe' "$output/datasaver-launch.log"
attempt=0
until docker exec "$container" timeout 5 test -s "$result_file"; do
  attempt=$((attempt+1)); [ "$attempt" -lt 45 ]; sleep 1
done
docker exec "$container" cat "$result_file" >"$output/datasaver-restored-observation.json"
pid=$(docker exec "$container" pidof org.royd.networkprobe)
case "$pid" in ''|*[!0-9]*) exit 1 ;; esac
[ "$(docker exec "$container" stat -c %u "/proc/$pid")" = "$uid_before" ]
[ "$(docker exec "$container" stat -c %u "$result_file")" = "$uid_before" ]
printf 'APP_PID=%s\nAPP_UID=%s\n' "$pid" "$uid_before" >"$output/datasaver-restored-identity.env"
app=pass
"$output/build/dns-fixture" -result "$output/datasaver-restored-observation.json" -expected "$gateway" -resolver "$resolver" \
  >"$output/datasaver-restored-app-assessment.env" || app=fail
if [ "$(grep -Fc 'query="datasaver=restored"' "$output/http-server.log")" -ne 2 ]; then app=fail; fi
docker exec "$container" logcat -d -s RoydNetworkProbe:I '*:S' >"$output/datasaver-application.log" 2>&1
docker exec "$container" input keyevent KEYCODE_WAKEUP
docker exec "$container" wm dismiss-keyguard
docker exec "$container" screencap -p >"$output/datasaver-restored.png"
[ "$activation" = pass ] && [ "$restoration" = pass ] && [ "$app" = pass ]
