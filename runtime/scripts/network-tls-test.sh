#!/bin/sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
image=${1:-${ROYD_IMAGE:-$($script_dir/default-image.sh standard x86_64)}}
output=${ROYD_NETWORK_TLS_OUTPUT_DIR:-$root/.work/network-tls-$(date -u +%Y%m%dT%H%M%SZ)-$$}
# Matches the pinned AOSP NetworkStack's HTTPS connectivity probe, not a runtime dependency.
url=${ROYD_NETWORK_TLS_URL:-https://www.google.com/generate_204}
http_status=${ROYD_NETWORK_TLS_HTTP_STATUS:-204}
mode=${ROYD_NETWORK_TLS_NETWORK_MODE:-bridge}
webview=${ROYD_NETWORK_TLS_WEBVIEW:-0}
# Use IANA's documentation page, not its best-effort example-domain service.
webview_url=${ROYD_NETWORK_TLS_WEBVIEW_URL:-https://www.iana.org/help/example-domains}
webview_title=${ROYD_NETWORK_TLS_WEBVIEW_TITLE:-Example Domains}
evidence_format=1
scope=ordinary-app-public-dns-https
default_timeout=60
if [ "$webview" = 1 ]; then evidence_format=2; scope=ordinary-app-public-dns-https-webview; default_timeout=90; fi
request_timeout=${ROYD_NETWORK_TLS_REQUEST_TIMEOUT:-$default_timeout}
rounds=${ROYD_NETWORK_TLS_ROUNDS:-1}
interval=${ROYD_NETWORK_TLS_INTERVAL:-0}
completed=0
round=0
round_results=not-tested
workload_elapsed=0
workload_started=
workload_finished=0
app_uid_first=
if [ "$rounds" != 1 ]; then evidence_format=3; scope=$scope-repetition; fi
build_runner=${ROYD_NETWORK_TLS_BUILD_RUNNER:-$script_dir/network-tls-build.sh}
assert_runner=${ROYD_NETWORK_TLS_ASSERT_RUNNER:-$script_dir/assert-runtime.sh}
container=royd-network-tls-$$
volume=$container-data
network=bridge
network_owned=0
container_owned=0
volume_owned=0
fixture_pid=
image_id=unknown
result=fail
runtime=not-tested
ownership=not-tested
control=not-tested
started=$(date -u +%FT%TZ)
case "$output" in ''|/|.|..) exit 2 ;; esac
case "$http_status" in 2[0-9][0-9]) ;; *) exit 2 ;; esac
case "$mode" in bridge|private) ;; *) exit 2 ;; esac
case "$webview" in 0|1) ;; *) exit 2 ;; esac
case "$request_timeout" in ''|*[!0-9]*|0) exit 2 ;; esac
case "$rounds" in [1-9]|[1-9][0-9]|100) ;; *) exit 2 ;; esac
case "$interval" in 0|[1-9]|[1-9][0-9]|[12][0-9][0-9]|300) ;; *) exit 2 ;; esac
for command in docker go; do command -v "$command" >/dev/null 2>&1 || exit 1; done
case "${DOCKER_HOST:-unix:///var/run/docker.sock}" in unix://*) ;; *) exit 2 ;; esac
case "$(docker context inspect --format '{{.Endpoints.docker.Host}}')" in unix://*) ;; *) exit 2 ;; esac
if docker inspect "$container" >/dev/null 2>&1 || docker volume inspect "$volume" >/dev/null 2>&1; then
  printf '%s\n' 'error: TLS test resource already exists' >&2; exit 1
fi
mkdir -p "$(dirname -- "$output")"
mkdir "$output" || { printf '%s\n' 'error: TLS evidence directory must be new' >&2; exit 1; }
output=$(CDPATH= cd -- "$output" && pwd)
finish() {
  status=$?
  trap - EXIT HUP INT TERM
  if [ -n "$fixture_pid" ]; then kill "$fixture_pid" 2>/dev/null || true; wait "$fixture_pid" || true; fi
  if [ "$container_owned" = 1 ]; then
    "$script_dir/container-evidence.sh" "$container" "$output/container" >"$output/capture.log" 2>&1 || status=1
  fi
  [ "$status" -eq 0 ] || result=fail
  if [ -n "$workload_started" ] && [ "$workload_finished" = 0 ]; then
    workload_elapsed=$(( $(cut -d. -f1 /proc/uptime) - workload_started ))
  fi
  cat >"$output/manifest.env" <<MANIFEST
ROYD_NETWORK_TLS_EVIDENCE_FORMAT=$evidence_format
NETWORK_SCOPE=$scope
WEBVIEW_ENABLED=$webview
NETWORK_MODE=$mode
RESULT_STATUS=$result
RUNTIME_STATUS=$runtime
OCI_OWNERSHIP_STATUS=$ownership
IMAGE=$image
IMAGE_ID=$image_id
TRUST_POLICY=platform-default
CONTROL_SERVER_STATUS=$control
EXPECTED_HTTP_STATUS=$http_status
STARTED_AT=$started
FINISHED_AT=$(date -u +%FT%TZ)
MANIFEST
  if [ "$rounds" -gt 1 ]; then
    printf 'REQUESTED_ROUNDS=%s\nCOMPLETED_ROUNDS=%s\nLAST_ROUND=%s\nROUND_RESULTS_STATUS=%s\nROUND_INTERVAL_SECONDS=%s\nWORKLOAD_ELAPSED_SECONDS=%s\n' \
      "$rounds" "$completed" "$round" "$round_results" "$interval" "$workload_elapsed" >>"$output/manifest.env"
  fi
  if [ "$webview" = 1 ] && [ -f "$output/target.env" ]; then
    sed -n '/^WEBVIEW_\(URL\|EXPECTED_TITLE\)=/p' "$output/target.env" >>"$output/manifest.env"
  fi
  if [ -f "$output/assessment.env" ]; then
    sed -n '/^\(OBSERVATION\|PUBLIC_DNS\|PUBLIC_HTTPS\|UNTRUSTED_CERT\|FRAMEWORK_NETWORK\|WEBVIEW_DOCUMENT\|WEBVIEW_UNTRUSTED_CERT\)_STATUS=\(pass\|fail\)$/p' "$output/assessment.env" >>"$output/manifest.env"
  fi
  if [ "$container_owned" = 1 ]; then docker rm -f "$container" >/dev/null 2>&1 || true; fi
  if [ "$volume_owned" = 1 ]; then docker volume rm "$volume" >/dev/null 2>&1 || true; fi
  if [ "$network_owned" = 1 ]; then docker network rm "$network" >/dev/null 2>&1 || true; fi
  exit "$status"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM
"$build_runner" "$output/build" >"$output/build.log" 2>&1
set --
if [ "$webview" = 1 ]; then set -- -webview-url "$webview_url" -webview-title "$webview_title"; fi
"$output/build/tls-fixture" -check-url "$url" "$@" >"$output/target.env"
image_id=$(docker image inspect --format '{{.Id}}' "$image")
if [ "$mode" = private ]; then
  network=$container-net
  if docker network inspect "$network" >/dev/null 2>&1; then exit 1; fi
  docker network create "$network" >"$output/network.log"
  network_owned=1
fi
gateway=$(docker network inspect "$network" --format '{{(index .IPAM.Config 0).Gateway}}')
"$output/build/tls-fixture" -listen "$gateway:0" >"$output/tls-server.log" 2>&1 &
fixture_pid=$!
attempt=0
until grep -q '^UNTRUSTED_URL=' "$output/tls-server.log"; do
  kill -0 "$fixture_pid"
  attempt=$((attempt + 1)); [ "$attempt" -lt 10 ]; sleep 1
done
untrusted=$(sed -n 's/^UNTRUSTED_URL=//p' "$output/tls-server.log")
docker volume create "$volume" >"$output/volume.log"
volume_owned=1
security_args=$("$script_dir/security-args.sh" privileged)
container_args=$("$script_dir/container-args.sh")
profile_args=$(ROYD_RESOURCE_PROFILE=low-memory "$script_dir/profile.sh" default)
# Deliberately inherit Docker DNS. No --dns, hosts override, proxy or trust-store mutation.
# shellcheck disable=SC2086
docker create $security_args $container_args --network "$network" --name "$container" \
  -v "$volume:/data" "$image_id" $profile_args >"$output/create.log"
container_owned=1
docker start "$container" >>"$output/create.log"
ROYD_BOOT_WAIT_MARKER='ROYD: using delegated cgroup v2 subtree' \
  "${ROYD_NETWORK_TLS_WAIT_RUNNER:-$script_dir/wait-for-boot.sh}" "$container" "${ROYD_BOOT_TIMEOUT:-180}" >"$output/boot.log" 2>&1
"${ROYD_NETWORK_TLS_HEALTH_RUNNER:-$script_dir/wait-for-health.sh}" "$container" "${ROYD_HEALTH_TIMEOUT:-240}" >"$output/health.log" 2>&1
"${ROYD_NETWORK_TLS_SECURITY_RUNNER:-$script_dir/assert-security.sh}" "$container" privileged >"$output/security.log" 2>&1
[ "$(docker exec "$container" getprop ro.build.version.sdk)" = 35 ]
docker inspect --format '{{with index .NetworkSettings.Networks "'"$network"'"}}{{.IPAddress}}/{{.IPPrefixLen}} {{.Gateway}}{{end}}' "$container" >"$output/oci-endpoint.txt"
endpoint=$(cat "$output/oci-endpoint.txt")
expected_cidr=${endpoint% *}
[ "${endpoint#* }" = "$gateway" ]
snapshot_oci() {
  docker exec "$container" sh -c 'ip -o -4 addr show dev eth0; ip -4 route show table main; ip link show dev eth0; cat /etc/resolv.conf'
}
snapshot_oci >"$output/oci-before.log"
grep -Fq "inet $expected_cidr " "$output/oci-before.log"
grep -Fq "default via $gateway dev eth0" "$output/oci-before.log"
ROYD_HAL_PROFILE=graphical ROYD_GRAPHICS_BACKEND=software ROYD_RESOURCE_PROFILE=low-memory \
  "$assert_runner" "$container" >"$output/before-runtime.log" 2>&1
system_before=$(docker exec "$container" pidof system_server)
case "$system_before" in ''|*[!0-9]*) exit 1 ;; esac
docker cp "$output/build/probe.apk" "$container:/data/local/tmp/royd-tls-probe.apk"
docker exec "$container" timeout 30 pm install -t /data/local/tmp/royd-tls-probe.apk >"$output/install.log" 2>&1
grep -Fxq Success "$output/install.log"
runtime_identity() {
  docker inspect --format '{{.Id}} {{.State.Running}} {{.State.StartedAt}} {{.RestartCount}} {{.State.OOMKilled}}' "$container"
}
if [ "$rounds" -gt 1 ]; then
  runtime_identity >"$output/runtime-before.txt"
  # Docker start time detects manual restarts which need not increment RestartCount.
  grep -Eq '^[0-9a-f]{64} true [0-9T:Z.+-]+ 0 false$' "$output/runtime-before.txt"
  ! grep -Fq '0001-01-01' "$output/runtime-before.txt"
  mkdir "$output/rounds"
fi
assessment=0
round_results=fail
workload_started=$(cut -d. -f1 /proc/uptime)
while [ "$round" -lt "$rounds" ]; do
round=$((round + 1))
round_output=$output
result_name=result.json
if [ "$rounds" -gt 1 ]; then
  round_id=$(printf '%03d' "$round")
  round_output=$output/rounds/$round_id
  mkdir "$round_output"
  result_name=round-$round_id.json
  printf 'ROUND=%s\nRESULT_STATUS=fail\n' "$round" >"$round_output/manifest.env"
  kill -0 "$fixture_pid"
  docker exec "$container" timeout 15 am force-stop --user 0 org.royd.tlsprobe >"$round_output/stop.log" 2>&1
  pid_status=0
  docker exec "$container" pidof org.royd.tlsprobe >"$round_output/stopped-pid.txt" || pid_status=$?
  [ "$pid_status" -eq 1 ]
  [ ! -s "$round_output/stopped-pid.txt" ]
  docker exec "$container" timeout 10 input keyevent KEYCODE_WAKEUP
  docker exec "$container" timeout 10 wm dismiss-keyguard
fi
set -- --es url "$url" --es untrusted "$untrusted"
if [ "$webview" = 1 ]; then set -- "$@" --es webview_url "$webview_url"; fi
if [ "$rounds" -gt 1 ]; then set -- "$@" --es result_name "$result_name"; fi
docker exec "$container" timeout 30 am start -W -n org.royd.tlsprobe/.TlsProbe "$@" >"$round_output/launch.log" 2>&1
grep -Fxq 'Status: ok' "$round_output/launch.log"
grep -Fxq 'Activity: org.royd.tlsprobe/.TlsProbe' "$round_output/launch.log"
if [ "$rounds" -gt 1 ]; then grep -Fxq 'LaunchState: COLD' "$round_output/launch.log"; fi
result_file=/data/user/0/org.royd.tlsprobe/files/$result_name
attempt=0
until docker exec "$container" timeout 5 test -s "$result_file"; do
  attempt=$((attempt + 1)); [ "$attempt" -lt "$request_timeout" ]; sleep 1
done
docker exec "$container" cat "$result_file" >"$round_output/observation.json"
app_pid=$(docker exec "$container" pidof org.royd.tlsprobe)
case "$app_pid" in ''|*[!0-9]*) exit 1 ;; esac
app_uid=$(docker exec "$container" stat -c %u "/proc/$app_pid")
case "$app_uid" in ''|*[!0-9]*) exit 1 ;; esac
file_uid=$(docker exec "$container" stat -c %u "$result_file")
printf 'APP_PID=%s\nAPP_UID=%s\nRESULT_UID=%s\nSYSTEM_SERVER=%s\n' "$app_pid" "$app_uid" "$file_uid" "$system_before" >"$round_output/application.env"
[ "$app_uid" -ge 10000 ]
[ "$app_uid" = "$file_uid" ]
if [ -z "$app_uid_first" ]; then app_uid_first=$app_uid; fi
[ "$app_uid" = "$app_uid_first" ]
sleep 2
docker exec "$container" logcat -d -s RoydTlsProbe:I '*:S' >"$round_output/application.log" 2>&1
docker exec "$container" screencap -p >"$round_output/application.png"
set --
if [ "$webview" = 1 ]; then set -- -webview-url "$webview_url" -webview-title "$webview_title"; fi
if [ "$rounds" -gt 1 ]; then set -- "$@" -result-name "$result_name"; fi
round_assessment=0
"$output/build/tls-fixture" -result "$round_output/observation.json" -url "$url" -untrusted "$untrusted" \
  -status "$http_status" -uid "$app_uid" "$@" >"$round_output/assessment.env" || round_assessment=$?
if [ "$rounds" -gt 1 ]; then
  round_runtime=pass
  round_ownership=pass
  round_control=pass
  docker exec "$container" pidof system_server >"$round_output/system-server.txt"
  [ "$system_before" = "$(cat "$round_output/system-server.txt")" ] || round_runtime=fail
  runtime_identity >"$round_output/runtime.txt"
  cmp -s "$output/runtime-before.txt" "$round_output/runtime.txt" || round_runtime=fail
  snapshot_oci >"$round_output/oci.log"
  cmp -s "$output/oci-before.log" "$round_output/oci.log" || round_ownership=fail
  if ! kill -0 "$fixture_pid" 2>/dev/null || grep -Fq UNTRUSTED_HTTP_REQUEST=unexpected "$output/tls-server.log"; then round_control=fail; fi
  printf 'ROUND=%s\nRESULT_STATUS=fail\nRUNTIME_STATUS=%s\nOCI_OWNERSHIP_STATUS=%s\nCONTROL_SERVER_STATUS=%s\n' \
    "$round" "$round_runtime" "$round_ownership" "$round_control" >"$round_output/manifest.env"
  if [ "$round_runtime" != pass ] || [ "$round_ownership" != pass ] || [ "$round_control" != pass ]; then round_assessment=1; fi
fi
if [ "$round_assessment" -ne 0 ]; then assessment=1; break; fi
completed=$round
if [ "$rounds" -gt 1 ]; then
  sed 's/^RESULT_STATUS=fail$/RESULT_STATUS=pass/' "$round_output/manifest.env" >"$round_output/manifest.tmp"
  mv "$round_output/manifest.tmp" "$round_output/manifest.env"
  printf 'HTTPS repetition round %s/%s passed\n' "$round" "$rounds"
fi
if [ "$round" -lt "$rounds" ]; then sleep "$interval"; fi
done
if [ "$completed" = "$rounds" ]; then round_results=pass; fi
workload_elapsed=$(( $(cut -d. -f1 /proc/uptime) - workload_started ))
workload_finished=1
services='connectivity dnsresolver netd'
if [ "$webview" = 1 ]; then services="$services webviewupdate"; fi
for service in $services; do
  docker exec "$container" timeout 15 dumpsys "$service" >"$output/$service.log" 2>&1
done
docker exec "$container" timeout 15 dumpsys package org.royd.tlsprobe >"$output/package.log" 2>&1
docker exec "$container" sh -c 'cat /etc/resolv.conf; ip rule; ip route show table all; date -u' >"$output/routes-dns-time.log" 2>&1
runtime=pass
ROYD_HAL_PROFILE=graphical ROYD_GRAPHICS_BACKEND=software ROYD_RESOURCE_PROFILE=low-memory \
  "$assert_runner" "$container" >"$output/after-runtime.log" 2>&1 || runtime=fail
[ "$system_before" = "$(docker exec "$container" pidof system_server)" ] || runtime=fail
snapshot_oci >"$output/oci-after.log"
ownership=pass
cmp -s "$output/oci-before.log" "$output/oci-after.log" || ownership=fail
if [ "$rounds" -gt 1 ]; then
  runtime_identity >"$output/runtime-after.txt"
  cmp -s "$output/runtime-before.txt" "$output/runtime-after.txt" || runtime=fail
fi
control=pass
if ! kill -0 "$fixture_pid" 2>/dev/null || grep -Fq UNTRUSTED_HTTP_REQUEST=unexpected "$output/tls-server.log"; then control=fail; fi
if [ "$assessment" -ne 0 ] || [ "$round_results" != pass ] || [ "$runtime" != pass ] || [ "$ownership" != pass ] || [ "$control" != pass ]; then exit 1; fi
result=pass
printf 'Android 15 public DNS and HTTPS test passed: %s\n' "$output"
