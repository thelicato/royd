#!/bin/sh
# Real background-service traffic, not a foreground Data Saver activation check.
set -eu
container=${1:?container required}
output=${2:?evidence required}
gateway=${3:?DNS fixture required}
url=${4:?nonce URL required}
datasaver=${ROYD_NETWORK_DNS_SAVER_POLICY:-0}
case "$datasaver" in 0|1) ;; *) exit 2 ;; esac
[ "$(docker inspect --format '{{index .Config.Labels "org.royd.test"}} {{index .Config.Labels "org.royd.test.owner"}}' "$container")" = "network-dns $container" ]
target_uid=
control_uid=
restore_needed=0
denylist() { docker exec "$container" timeout 15 cmd netpolicy list restrict-background-blacklist; }
restore() {
  restore_status=0
  if [ "$datasaver" = 1 ]; then
    docker exec "$container" timeout 15 cmd netpolicy set restrict-background false || restore_status=1
    docker exec "$container" timeout 15 cmd netpolicy get restrict-background >"$output/saver-restored.log" || restore_status=1
    grep -Fxq 'Restrict background status: disabled' "$output/saver-restored.log" || restore_status=1
    for owned_uid in "$target_uid" "$control_uid"; do
      [ -z "$owned_uid" ] || docker exec "$container" timeout 15 cmd netpolicy remove restrict-background-whitelist "$owned_uid" || restore_status=1
    done
    docker exec "$container" timeout 15 cmd netpolicy list restrict-background-whitelist >"$output/saver-restored-allowlist.log" || restore_status=1
    cmp "$output/saver-initial-allowlist.log" "$output/saver-restored-allowlist.log" || restore_status=1
  else
    docker exec "$container" timeout 15 cmd netpolicy remove restrict-background-blacklist "$target_uid" || restore_status=1
  fi
  denylist >"$output/metered-restored-policy.log" || restore_status=1
  grep -Fxq 'Restrict background blacklisted UIDs: none' "$output/metered-restored-policy.log" || restore_status=1
  return "$restore_status"
}
finish() {
  status=$?
  trap - EXIT HUP INT TERM
  if [ "$restore_needed" = 1 ]; then restore >"$output/metered-cleanup.log" 2>&1 || status=1; fi
  exit "$status"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM
snapshot() { docker inspect --format '{{.Id}} {{.State.StartedAt}} {{.State.Running}} {{.RestartCount}} {{.State.OOMKilled}}' "$container"; }
snapshot >"$output/runtime-before.txt"
grep -Eq '^[a-f0-9]{64} [^ ]+ true 0 false$' "$output/runtime-before.txt"
denylist >"$output/metered-initial-policy.log"
grep -Fxq 'Restrict background blacklisted UIDs: none' "$output/metered-initial-policy.log"
docker exec "$container" timeout 15 cmd netpolicy get restrict-background >"$output/metered-datasaver.log"
grep -Fxq 'Restrict background status: disabled' "$output/metered-datasaver.log"
docker exec "$container" timeout 15 cmd netpolicy list restrict-background-whitelist >"$output/saver-initial-allowlist.log"
docker cp "$output/build/control.apk" "$container:/data/local/tmp/royd-network-control.apk"
docker exec "$container" timeout 30 pm install -t /data/local/tmp/royd-network-control.apk >"$output/control-install.log" 2>&1
grep -Fxq Success "$output/control-install.log"
phases='baseline blocked restored'
if [ "$datasaver" = 1 ]; then phases='baseline blocked exempt revoked foreground restored'; fi
for phase in $phases; do
  if [ "$datasaver" = 1 ]; then
    case "$phase" in
      blocked) restore_needed=1
        docker exec "$container" timeout 15 cmd netpolicy add restrict-background-whitelist "$control_uid" >"$output/saver-control-allow.log" 2>&1
        docker exec "$container" timeout 15 cmd netpolicy set restrict-background true >"$output/saver-enable.log" 2>&1 ;;
      exempt) docker exec "$container" timeout 15 cmd netpolicy add restrict-background-whitelist "$target_uid" >"$output/saver-target-allow.log" 2>&1 ;;
      revoked) docker exec "$container" timeout 15 cmd netpolicy remove restrict-background-whitelist "$target_uid" >"$output/saver-target-revoke.log" 2>&1 ;;
      restored) restore >"$output/metered-restore.log" 2>&1; restore_needed=0 ;;
    esac
    docker exec "$container" timeout 15 cmd netpolicy get restrict-background >"$output/saver-state-$phase.log"
    docker exec "$container" timeout 15 cmd netpolicy list restrict-background-whitelist >"$output/saver-allowlist-$phase.log"
  else
    case "$phase" in
      blocked)
        restore_needed=1
        docker exec "$container" timeout 15 cmd netpolicy add restrict-background-blacklist "$target_uid" >"$output/metered-deny.log" 2>&1 ;;
      restored) restore >"$output/metered-restore.log" 2>&1; restore_needed=0 ;;
    esac
  fi
  denylist >"$output/metered-policy-$phase.log"
  for role in target control; do
    package=org.royd.networkprobe
    if [ "$role" = control ]; then package=org.royd.networkcontrol; fi
    name=$phase-$role
    private=/data/user/0/$package/files
    docker exec "$container" timeout 15 am force-stop --user 0 "$package" >"$output/stop-$name.log" 2>&1
    status=0
    docker exec "$container" pidof "$package" >"$output/stopped-$name.txt" || status=$?
    [ "$status" -eq 1 ] && [ ! -s "$output/stopped-$name.txt" ]
    # Replace only generated observations belonging to these newly installed test APKs.
    docker exec "$container" rm -f "$private/ready.json" "$private/result.json" "$private/probe.trigger"
    docker exec "$container" input keyevent KEYCODE_WAKEUP
    docker exec "$container" wm dismiss-keyguard
    foreground=false
    if [ "$datasaver:$phase:$role" = 1:foreground:target ]; then foreground=true; fi
    docker exec "$container" timeout 30 am start --user 0 -n "$package/org.royd.networkprobe.MeteredProbeLauncher" \
      --es host royd-probe.test --es dns "$gateway" --es url "$url?metered=$name" --ez foreground "$foreground" >"$output/launch-$name.log" 2>&1
    if grep -Ei 'error|exception|not allowed|denied' "$output/launch-$name.log"; then exit 1; fi
    attempt=0
    until docker exec "$container" timeout 5 test -s "$private/ready.json"; do
      attempt=$((attempt+1)); [ "$attempt" -lt 30 ]; sleep 1
    done
    docker exec "$container" cat "$private/ready.json" >"$output/ready-$name.json"
    pid=$(docker exec "$container" pidof "$package")
    case "$pid" in ''|*[!0-9]*) exit 1 ;; esac
    uid=$(docker exec "$container" stat -c %u "/proc/$pid")
    case "$uid" in ''|*[!0-9]*) exit 1 ;; esac
    [ "$uid" -ge 10000 ]
    if [ "$phase:$role" = baseline:target ]; then target_uid=$uid; fi
    if [ "$phase:$role" = baseline:control ]; then control_uid=$uid; fi
    if [ "$phase" = baseline ]; then
      # Only mutate policies of fresh ordinary UIDs which were not already exempt.
      if grep -Eq "(^|[[:space:]])$uid([[:space:]]|$)" "$output/saver-initial-allowlist.log"; then exit 1; fi
    fi
    printf '%s %s\n' "$pid" "$uid" >"$output/$name.identity"
    attempt=0
    while :; do
      docker exec "$container" timeout 15 dumpsys connectivity trafficcontroller >"$output/bpf-$name.log" 2>&1
      row=$(awk -v uid="$uid" '/sUidOwnerMap:/ {owner=1; next} /sUidPermissionMap:/ {owner=0} owner && $1 == uid {print}' "$output/bpf-$name.log")
      valid=1
      if [ "$datasaver" = 1 ]; then
        happy=0
        if [ "$phase" != baseline ] && [ "$phase" != restored ] && { [ "$role" = control ] || [ "$phase" = exempt ] || [ "$foreground" = true ]; }; then happy=1; fi
        if [ "$happy" = 1 ]; then printf '%s\n' "$row" | grep -qw HAPPY_BOX_MATCH || valid=0
        elif printf '%s\n' "$row" | grep -qw HAPPY_BOX_MATCH; then valid=0; fi
        if printf '%s\n' "$row" | grep -Eq 'PENALTY_BOX_(USER|ADMIN)_MATCH'; then valid=0; fi
        saver=true
        if [ "$phase" = baseline ] || [ "$phase" = restored ]; then saver=false; fi
        grep -Eq "^[[:space:]]*sDataSaverEnabledMap: $saver$" "$output/bpf-$name.log" || valid=0
        if [ "$foreground" = false ]; then printf '%s\n' "$row" | grep -qw BACKGROUND_MATCH || valid=0; fi
      else
        printf '%s\n' "$row" | grep -qw BACKGROUND_MATCH || valid=0
        if printf '%s\n' "$row" | grep -qw HAPPY_BOX_MATCH; then valid=0; fi
        if [ "$phase:$role" = blocked:target ]; then
          printf '%s\n' "$row" | grep -qw PENALTY_BOX_USER_MATCH || valid=0
        elif printf '%s\n' "$row" | grep -qw PENALTY_BOX_USER_MATCH; then valid=0; fi
      fi
      [ "$valid" = 0 ] || break
      attempt=$((attempt+1)); [ "$attempt" -lt 30 ]; sleep 1
    done
    docker exec "$container" timeout 15 am get-uid-state "$uid" >"$output/uid-state-$name.log" 2>&1
    docker exec "$container" timeout 15 dumpsys netpolicy >"$output/netpolicy-$name.log" 2>&1
    grep -Eq 'Metered ifaces: \{eth0\}' "$output/netpolicy-$name.log"
    docker exec "$container" touch "$private/probe.trigger"
    attempt=0
    until docker exec "$container" timeout 5 test -s "$private/result.json"; do
      attempt=$((attempt+1)); [ "$attempt" -lt 45 ]; sleep 1
    done
    docker exec "$container" cat "$private/result.json" >"$output/$name.json"
    [ "$(docker exec "$container" stat -c %u "$private/result.json")" = "$uid" ]
    [ "$(docker exec "$container" pidof "$package")" = "$pid" ]
    docker exec "$container" timeout 15 am get-uid-state "$uid" >"$output/uid-state-after-$name.log" 2>&1
    snapshot >"$output/runtime-$name.txt"
    cmp "$output/runtime-before.txt" "$output/runtime-$name.txt"
  done
done
docker exec "$container" logcat -d -s RoydMeteredProbe:I '*:S' >"$output/application.log" 2>&1
