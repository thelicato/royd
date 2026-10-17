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
request_timeout=${ROYD_NETWORK_TLS_REQUEST_TIMEOUT:-60}
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
case "$request_timeout" in ''|*[!0-9]*|0) exit 2 ;; esac
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
  cat >"$output/manifest.env" <<MANIFEST
ROYD_NETWORK_TLS_EVIDENCE_FORMAT=1
NETWORK_SCOPE=ordinary-app-public-dns-https
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
  if [ -f "$output/assessment.env" ]; then
    sed -n '/^\(OBSERVATION\|PUBLIC_DNS\|PUBLIC_HTTPS\|UNTRUSTED_CERT\|FRAMEWORK_NETWORK\)_STATUS=\(pass\|fail\)$/p' "$output/assessment.env" >>"$output/manifest.env"
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
"$output/build/tls-fixture" -check-url "$url" >"$output/target.env"
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
docker exec "$container" timeout 30 am start -W -n org.royd.tlsprobe/.TlsProbe \
  --es url "$url" --es untrusted "$untrusted" >"$output/launch.log" 2>&1
grep -Fxq 'Status: ok' "$output/launch.log"
grep -Fxq 'Activity: org.royd.tlsprobe/.TlsProbe' "$output/launch.log"
result_file=/data/user/0/org.royd.tlsprobe/files/result.json
attempt=0
until docker exec "$container" timeout 5 test -s "$result_file"; do
  attempt=$((attempt + 1)); [ "$attempt" -lt "$request_timeout" ]; sleep 1
done
docker exec "$container" cat "$result_file" >"$output/observation.json"
app_pid=$(docker exec "$container" pidof org.royd.tlsprobe)
case "$app_pid" in ''|*[!0-9]*) exit 1 ;; esac
app_uid=$(docker exec "$container" stat -c %u "/proc/$app_pid")
case "$app_uid" in ''|*[!0-9]*) exit 1 ;; esac
[ "$app_uid" -ge 10000 ]
[ "$app_uid" = "$(docker exec "$container" stat -c %u "$result_file")" ]
printf 'APP_PID=%s\nAPP_UID=%s\nSYSTEM_SERVER=%s\n' "$app_pid" "$app_uid" "$system_before" >"$output/application.env"
sleep 2
docker exec "$container" logcat -d -s RoydTlsProbe:I '*:S' >"$output/application.log" 2>&1
docker exec "$container" screencap -p >"$output/application.png"
for service in connectivity dnsresolver netd; do
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
assessment=0
"$output/build/tls-fixture" -result "$output/observation.json" -url "$url" -untrusted "$untrusted" \
  -status "$http_status" -uid "$app_uid" >"$output/assessment.env" || assessment=$?
control=pass
if ! kill -0 "$fixture_pid" 2>/dev/null || grep -Fq UNTRUSTED_HTTP_REQUEST=unexpected "$output/tls-server.log"; then control=fail; fi
if [ "$assessment" -ne 0 ] || [ "$runtime" != pass ] || [ "$ownership" != pass ] || [ "$control" != pass ]; then exit 1; fi
result=pass
printf 'Android 15 public DNS and HTTPS test passed: %s\n' "$output"
