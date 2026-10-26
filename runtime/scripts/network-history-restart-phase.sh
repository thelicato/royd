#!/bin/sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
container=${1:?container required}
output=${2:?restart evidence required}
phase=${3:?restart phase required}
case "$phase" in fresh|restart|recreate|framework) ;; *) exit 2 ;; esac
[ "$(docker inspect --format '{{index .Config.Labels "org.royd.test"}} {{index .Config.Labels "org.royd.test.owner"}}' "$container")" = "restart $container" ]
directory=$output/$phase/history
mkdir "$directory"
fixture_pid=
finish() {
  status=$?
  trap - EXIT HUP INT TERM
  if [ -n "$fixture_pid" ]; then
    kill -0 "$fixture_pid" 2>/dev/null || status=1
    kill "$fixture_pid" 2>/dev/null || status=1
    fixture_status=0
    wait "$fixture_pid" 2>"$directory/fixture-stop.log" || fixture_status=$?
    printf 'FIXTURE_EXIT_STATUS=%s\n' "$fixture_status" >"$directory/fixture-stop.env"
    [ "$fixture_status" = 143 ] || status=1
  fi
  docker exec "$container" timeout 15 am force-stop org.royd.networkprobe >"$directory/cleanup.log" 2>&1 || status=1
  printf 'PHASE_EXIT_STATUS=%s\n' "$status" >"$directory/result.env"
  exit "$status"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM
numeric() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; }
system_before=$(docker exec "$container" pidof system_server)
numeric "$system_before"
if [ "$phase" = fresh ]; then
  "$script_dir/network-history-build.sh" "$output/history-build" >"$directory/build.log" 2>&1
  gateway=$(docker inspect --format '{{(index .NetworkSettings.Networks "bridge").Gateway}}' "$container")
  "$output/history-build/http-fixture" -listen "$gateway:0" >"$directory/fixture.log" 2>&1 &
  fixture_pid=$!
  attempt=0
  until grep -q '^URL=' "$directory/fixture.log"; do
    attempt=$((attempt + 1)); [ "$attempt" -lt 10 ]; kill -0 "$fixture_pid"; sleep 1
  done
  url=$(sed -n 's/^URL=//p' "$directory/fixture.log")
  docker cp "$output/history-build/probe.apk" "$container:/data/local/tmp/royd-history-probe.apk"
  docker exec "$container" timeout 30 pm install -t /data/local/tmp/royd-history-probe.apk >"$directory/install.log" 2>&1
  grep -Fxq Success "$directory/install.log"
  docker exec "$container" input keyevent KEYCODE_WAKEUP
  docker exec "$container" wm dismiss-keyguard
  docker exec "$container" timeout 30 am start -W -n org.royd.networkprobe/.HistorySeedProbe --es url "$url" >"$directory/seed-launch.log" 2>&1
  grep -Fxq 'Status: ok' "$directory/seed-launch.log"
  seed=/data/user/0/org.royd.networkprobe/files/seed.json
  attempt=0
  until docker exec "$container" timeout 5 test -s "$seed"; do
    attempt=$((attempt + 1)); [ "$attempt" -lt 30 ]; sleep 1
  done
  pid=$(docker exec "$container" pidof org.royd.networkprobe)
  numeric "$pid"
  uid=$(docker exec "$container" stat -c %u "/proc/$pid")
  numeric "$uid"; [ "$uid" -ge 10000 ]
  [ "$(docker exec "$container" stat -c %u "$seed")" = "$uid" ]
  docker exec "$container" cat "$seed" >"$directory/seed.json"
  python3 - "$directory/seed.json" "$uid" "$pid" "$url" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
assert r['uid'] == int(sys.argv[2]) and r['pid'] == int(sys.argv[3]) and r['url'] == sys.argv[4]
assert r['done'] is True and r.get('error', '') == '' and r['interface'] == 'eth0'
assert r['http_status'] == 200 and r['body_nonce'] is True and r['body_bytes'] > 0
PY
  nonce=${url##*/}
  grep -Fq "request method=\"GET\" path=\"/page/$nonce\"" "$directory/fixture.log"
  docker exec "$container" timeout 15 am force-stop org.royd.networkprobe
  now=$(docker exec "$container" date +%s)
  numeric "$now"
  query_end=$(((now + 86400) * 1000))
  printf 'APP_UID=%s\nQUERY_END=%s\n' "$uid" "$query_end" >"$directory/query.env"
else
  uid=$(sed -n 's/^APP_UID=//p' "$output/fresh/history/query.env")
  query_end=$(sed -n 's/^QUERY_END=//p' "$output/fresh/history/query.env")
  numeric "$uid"; numeric "$query_end"; [ "$uid" -ge 10000 ]
  docker exec "$container" cat /data/user/0/org.royd.networkprobe/files/seed.json >"$directory/seed.json"
  cmp "$output/fresh/history/seed.json" "$directory/seed.json"
fi
docker exec "$container" cmd package list packages -U org.royd.networkprobe >"$directory/package.txt"
grep -Fxq "package:org.royd.networkprobe uid:$uid" "$directory/package.txt"
docker exec "$container" stat -c %u /data/user/0/org.royd.networkprobe/files/seed.json >"$directory/seed-owner.txt"
[ "$(cat "$directory/seed-owner.txt")" = "$uid" ]
docker exec "$container" timeout 10 sh -c '
  set -eu
  if pidof org.royd.networkprobe; then
    echo "error: seed application is still running before restored history read" >&2
    exit 1
  else
    test "$?" = 1
  fi
  echo SEED_APPLICATION_ABSENT
' >"$directory/absent-process.log" 2>&1
grep -Fxq SEED_APPLICATION_ABSENT "$directory/absent-process.log"
# Read restored history before launching any application or requesting a new poll.
# Only the fresh phase explicitly persists its seed through stock NetworkStatsService.
for label in first second; do
  if [ "$phase" = fresh ]; then
    docker exec "$container" timeout 30 dumpsys netstats --poll >"$directory/poll-$label.log" 2>&1
    grep -Fxq 'Forced poll' "$directory/poll-$label.log"
  fi
  docker exec "$container" timeout 20 dumpsys netstats --uid --tag --full >"$directory/native-$label.log" 2>&1
done
"$output/history-assess" -evidence "$directory" -stats-directory >"$directory/stats-directory.txt" 2>"$directory/directory.log"
stats_dir=$(cat "$directory/stats-directory.txt")
docker exec "$container" sh -c '
  set -eu
  found=0
  for file in "$1"/uid.*; do
    if test -s "$file"; then stat -c "%n %s" "$file"; found=1; fi
  done
  if test "$found" != 1; then echo "error: no non-empty UID recorder files in $1" >&2; exit 1; fi
' sh "$stats_dir" >"$directory/persisted-files.log" 2>&1
docker cp "$container:$stats_dir" "$directory/netstats"
label=other-$phase
docker exec "$container" input keyevent KEYCODE_WAKEUP
docker exec "$container" wm dismiss-keyguard
docker exec "$container" timeout 30 am start -W --activity-clear-top -n org.royd.networkprobe/.UsageHistoryProbe \
  --es label "$label" --ei query_uid 1000 --el query_end "$query_end" >"$directory/denial-launch.log" 2>&1
grep -Fxq 'Status: ok' "$directory/denial-launch.log"
file=/data/user/0/org.royd.networkprobe/files/history-$label.json
attempt=0
until docker exec "$container" timeout 5 test -s "$file"; do
  attempt=$((attempt + 1)); [ "$attempt" -lt 30 ]; sleep 1
done
[ "$(docker exec "$container" stat -c %u "$file")" = "$uid" ]
docker exec "$container" cat "$file" >"$directory/history-$label.json"
reference=$output/fresh/history/native-first.log
"$output/history-assess" -evidence "$directory" -uid "$uid" -end "$query_end" -label "$label" -reference "$reference" >"$directory/assessment.env" 2>"$directory/assessment.log"
[ "$system_before" = "$(docker exec "$container" pidof system_server)" ]
