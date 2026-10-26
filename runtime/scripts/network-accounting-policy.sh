#!/bin/bash
# Internal functions for the accounting runner's labelled disposable container.
policy_owner() {
 [ "$(docker inspect --format '{{index .Config.Labels "org.royd.test"}} {{index .Config.Labels "org.royd.test.owner"}}' "$container")" = "network-accounting $container" ]
}
policy_restore() {
 local restore_status=0 package
 policy_owner || return 1
 docker exec "$container" timeout 15 cmd connectivity set-package-networking-enabled true org.royd.networkprobe || restore_status=1
 docker exec "$container" timeout 15 cmd connectivity set-chain3-enabled false || restore_status=1
 docker exec "$container" timeout 15 cmd connectivity get-chain3-enabled >"$output/policy-restored-chain.log" || restore_status=1
 grep -Fxq chain:disabled "$output/policy-restored-chain.log" || restore_status=1
 for package in org.royd.networkprobe org.royd.networkcontrol; do
  docker exec "$container" timeout 15 cmd connectivity get-package-networking-enabled "$package" >"$output/policy-restored-$package.log" || restore_status=1
  grep -Fxq "$package:allow" "$output/policy-restored-$package.log" || restore_status=1
 done
 return "$restore_status"
}
policy_wait() {
 local role=$1 name=$2 destination=$3 attempt observation
 local deadline
 deadline=$(python3 -c 'import time; print(time.monotonic()+20)')
 for attempt in $(seq 1 50); do
  observation=$(docker exec "$container" timeout 5 sh -c '
   if test -s "$1/error.json"; then printf "error\n";
   elif test -s "$1/$2.json"; then printf "ready\n";
   elif pidof "$3" >/dev/null; then printf "pending\n";
   else printf "dead\n"; fi' sh "${policy_directories[$role]}" "$name" "${policy_packages[$role]}")
  case "$observation" in
   error) docker exec "$container" cat "${policy_directories[$role]}/error.json" >"$output/policy-app-error-$role.json"; return 1 ;;
   ready) docker exec "$container" cat "${policy_directories[$role]}/$name.json" >"$destination"; return 0 ;;
   dead) printf 'error: application accounting process exited: %s\n' "${policy_packages[$role]}" >&2; return 1 ;;
   pending) ;;
   *) return 1 ;;
  esac
  if ! python3 - "$deadline" <<'PYWAIT'
import sys,time
sys.exit(0 if time.monotonic()<float(sys.argv[1]) else 1)
PYWAIT
  then break; fi
  sleep 0.1
 done
 printf 'error: application accounting observation timed out: %s/%s\n' "$role" "$name" >&2
 return 1
}
policy_command() {
 local role=$1 phase=$2
 docker exec --user "${policy_uids[$role]}:${policy_uids[$role]}" "$container" timeout 5 sh -c \
  'set -eC
   printf "%s\n" "$1" > "$2.tmp"
   ln "$2.tmp" "$2"
   rm "$2.tmp"' sh "${fixture[1]}" "${policy_directories[$role]}/command-$phase" || return 1
 docker exec "$container" cat "${policy_directories[$role]}/command-$phase" >"$output/policy-command-$role-$phase.txt"
}
policy_snapshot() {
 local phase=$1 role=$2 package
 docker exec "$container" timeout 15 cmd connectivity get-chain3-enabled >"$output/phase-$phase/chain.log"
 for package in org.royd.networkprobe org.royd.networkcontrol; do
  docker exec "$container" timeout 15 cmd connectivity get-package-networking-enabled "$package" >"$output/phase-$phase/rule-$package.log"
 done
 docker exec "$container" timeout 15 dumpsys connectivity trafficcontroller >"$output/phase-$phase/bpf.log"
 docker exec "$container" timeout 15 am get-uid-state "${policy_uids[$role]}" >"$output/phase-$phase/uid-state-before.log"
 grep -Fxq '10 (SERVICE)' "$output/phase-$phase/uid-state-before.log"
}
policy_workload() {
 policy_owner
 local role package apk component phase uid pid
 policy_packages=(org.royd.networkprobe org.royd.networkcontrol)
 policy_uids=() policy_pids=() policy_directories=()
 docker exec "$container" timeout 15 cmd connectivity get-chain3-enabled >"$output/policy-initial-chain.log"
 grep -Fxq chain:disabled "$output/policy-initial-chain.log"
 for role in 0 1; do
  package=${policy_packages[$role]}
  [ -z "$(docker exec "$container" timeout 10 pm path "$package")" ]
  apk=probe.apk; [ "$role" = 0 ] || apk=control.apk
  docker cp "$output/policy-build/$apk" "$container:/data/local/tmp/royd-accounting-$role.apk"
  docker exec "$container" timeout 30 pm install -t "/data/local/tmp/royd-accounting-$role.apk" >"$output/policy-install-$role.log" 2>&1
  grep -Fxq Success "$output/policy-install-$role.log"
  docker exec "$container" timeout 15 cmd connectivity get-package-networking-enabled "$package" >"$output/policy-initial-$package.log"
  grep -Fxq "$package:allow" "$output/policy-initial-$package.log"
  policy_directories+=("/data/user/0/$package/files/accounting-${fixture[1]}")
  docker exec "$container" input keyevent KEYCODE_WAKEUP
  docker exec "$container" wm dismiss-keyguard
  component=$package/org.royd.networkprobe.AccountingProbeLauncher
  local role_name=target; [ "$role" = 0 ] || role_name=control
  docker exec "$container" timeout 30 am start -W -n "$component" --es address "${fixture[0]}" --es nonce "${fixture[1]}" --es role "$role_name" >"$output/policy-launch-$role.log" 2>&1
  grep -Fxq 'Status: ok' "$output/policy-launch-$role.log"
  policy_wait "$role" ready "$output/policy-ready-$role.json"
  pid=$(docker exec "$container" pidof "$package")
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  uid=$(docker exec "$container" stat -c %u "/proc/$pid")
  case "$uid" in ''|*[!0-9]*) return 1 ;; esac
  [ "$uid" -ge 10000 ] && [ "$uid" -lt 20000 ]
  [ "$(docker exec "$container" stat -c %u "${policy_directories[$role]}/ready.json")" = "$uid" ]
  policy_uids+=("$uid"); policy_pids+=("$pid")
  printf '%s %s\n' "$pid" "$uid" >"$output/policy-identity-$role.txt"
 done
 [ "${policy_uids[0]}" != "${policy_uids[1]}" ]
 for phase in 8 9 10 11 12 13; do
  role=$(((phase - 8) % 2))
  mkdir "$output/phase-$phase"
  case "$phase" in
   10)
    policy_restore_needed=1
    docker exec "$container" timeout 15 cmd connectivity set-package-networking-enabled false org.royd.networkprobe >"$output/policy-deny.log" 2>&1
    docker exec "$container" timeout 15 cmd connectivity set-chain3-enabled true >>"$output/policy-deny.log" 2>&1 ;;
   12)
    policy_restore >"$output/policy-restore.log" 2>&1
    policy_restore_needed=0 ;;
  esac
  policy_snapshot "$phase" "$role"
  observe_snapshot "p$phase-before"
  policy_command "$role" "$phase"
  if [ "$phase" = 10 ]; then
   printf '{"phase":10,"uid":%s,"count":64}\n' "${policy_uids[0]}" >&"$fixture_input"
  fi
  policy_wait "$role" "phase-$phase" "$output/phase-$phase/app.json"
  observe_snapshot "p$phase-after"
  [ "$(docker exec "$container" pidof "${policy_packages[$role]}")" = "${policy_pids[$role]}" ]
  [ "$(docker exec "$container" stat -c %u "${policy_directories[$role]}/phase-$phase.json")" = "${policy_uids[$role]}" ]
  docker exec "$container" cat "/proc/${policy_pids[$role]}/status" >"$output/phase-$phase/proc-status.log"
  docker exec "$container" cat "/proc/${policy_pids[$role]}/cgroup" >"$output/phase-$phase/cgroup.log"
  docker exec "$container" timeout 15 am get-uid-state "${policy_uids[$role]}" >"$output/phase-$phase/uid-state-after.log"
  grep -Fxq '10 (SERVICE)' "$output/phase-$phase/uid-state-after.log"
 done
 PYTHONDONTWRITEBYTECODE=1 python3 "$root/runtime/tests/network-accounting/assess_policy.py" "$output" >"$output/policy-assessment.jsonl" 2>"$output/policy-assessment.log"
 for role in 0 1; do
  policy_command "$role" 14
  docker exec "$container" timeout 15 am force-stop --user 0 "${policy_packages[$role]}" >"$output/policy-stop-$role.log" 2>&1
 done
}
