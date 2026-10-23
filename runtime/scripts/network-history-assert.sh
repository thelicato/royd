#!/bin/sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
container=${1:?container required}
output=${ROYD_NETWORK_DNS_OUTPUT_DIR:?history evidence required}
[ "$(docker inspect --format '{{index .Config.Labels "org.royd.test"}} {{index .Config.Labels "org.royd.test.owner"}}' "$container")" = "network-dns $container" ]
directory=$output/history
if [ ! -d "$directory" ]; then
  mkdir "$directory"
  docker inspect --format '{{.Id}} {{.State.StartedAt}} {{.State.Running}} {{.RestartCount}} {{.State.OOMKilled}}' "$container" >"$directory/identity-before.txt"
  exec "$script_dir/assert-runtime.sh" "$container"
fi
[ ! -e "$directory/assessment.env" ]
finish_history() {
  workload_status=$?
  trap - EXIT HUP INT TERM
  runtime_status=0
  "$script_dir/assert-runtime.sh" "$container" || runtime_status=$?
  printf 'WORKLOAD_EXIT_STATUS=%s\nRUNTIME_EXIT_STATUS=%s\n' "$workload_status" "$runtime_status" >"$directory/workload.env"
  # The enclosing DNS runner records its independent runtime result. The wrapper
  # separately requires the complete history workload and assessment to pass.
  exit "$runtime_status"
}
trap finish_history EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM
uid=$(sed -n 's/^APP_UID=//p' "$output/application.env")
case "$uid" in ''|*[!0-9]*) exit 1 ;; esac
[ "$uid" -ge 10000 ]
# Include the whole current history bucket; keep one fixed interval for every query.
now=$(docker exec "$container" date +%s)
case "$now" in ''|*[!0-9]*) exit 1 ;; esac
query_end=$(((now + 86400) * 1000))
printf 'APP_UID=%s\nQUERY_END=%s\n' "$uid" "$query_end" >"$directory/query.env"
status=0
for label in first second; do
  docker exec "$container" timeout 30 dumpsys netstats --poll >"$directory/poll-$label.log" 2>&1
  grep -Fxq 'Forced poll' "$directory/poll-$label.log"
  docker exec "$container" timeout 20 dumpsys netstats --uid --tag --full >"$directory/native-$label.log" 2>&1
done
for label in other; do
  docker exec "$container" input keyevent KEYCODE_WAKEUP
  docker exec "$container" wm dismiss-keyguard
  docker exec "$container" timeout 30 am start -W --activity-clear-top -n org.royd.networkprobe/.UsageHistoryProbe \
    --es label "$label" --ei query_uid 1000 --el query_end "$query_end" >"$directory/launch-$label.log" 2>&1
  grep -Fxq 'Status: ok' "$directory/launch-$label.log"
  result=/data/user/0/org.royd.networkprobe/files/history-$label.json
  attempt=0
  until docker exec "$container" timeout 5 test -s "$result"; do
    attempt=$((attempt + 1)); [ "$attempt" -lt 30 ]; sleep 1
  done
  [ "$(docker exec "$container" stat -c %u "$result")" = "$uid" ]
  docker exec "$container" cat "$result" >"$directory/history-$label.json"
done
docker inspect --format '{{.Id}} {{.State.StartedAt}} {{.State.Running}} {{.RestartCount}} {{.State.OOMKilled}}' "$container" >"$directory/identity-after.txt"
cmp "$directory/identity-before.txt" "$directory/identity-after.txt" || status=1
"$output/history-assess" -evidence "$directory" -uid "$uid" -end "$query_end" >"$directory/assessment.env" 2>"$directory/assessment.log" || status=1
exit "$status"
