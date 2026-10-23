#!/bin/sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
image=${1:-${ROYD_IMAGE:-$($script_dir/default-image.sh standard x86_64)}}
output=${ROYD_NETWORK_DNS_OUTPUT_DIR:-$root/.work/network-dns-$(date -u +%Y%m%dT%H%M%SZ)-$$}
container=royd-network-dns-$$
volume=$container-data
network_mode=${ROYD_NETWORK_DNS_NETWORK_MODE:-bridge}
recovery=${ROYD_NETWORK_DNS_RECOVERY:-0}
policy=${ROYD_NETWORK_DNS_POLICY:-0}
datasaver=${ROYD_NETWORK_DNS_DATASAVER:-0}
metered=${ROYD_NETWORK_DNS_METERED:-0}
saver_policy=${ROYD_NETWORK_DNS_SAVER_POLICY:-0}
sleep_launch=${ROYD_NETWORK_METERED_SLEEP_BEFORE_LAUNCH:-0}
format=2
scope=app-system-dns-framework
if [ "$recovery" = 1 ]; then format=3; scope=continuous-app-ipv4-network-recovery; fi
if [ "$policy" = 1 ]; then format=4; scope=ordinary-uid-oem-deny3-policy; fi
if [ "$datasaver" = 1 ]; then format=5; scope=datasaver-activation-and-restored-app-controls; fi
if [ "$metered" = 1 ]; then format=6; scope=ordinary-background-uid-metered-policy; fi
if [ "$saver_policy" = 1 ]; then format=7; scope=data-saver-background-exemption-and-foreground-packets; fi
network=bridge
network_owned=0
build_runner=${ROYD_NETWORK_DNS_BUILD_RUNNER:-$script_dir/network-dns-build.sh}
assert_runner=${ROYD_NETWORK_DNS_ASSERT_RUNNER:-$script_dir/assert-runtime.sh}
request_timeout=${ROYD_NETWORK_DNS_REQUEST_TIMEOUT:-30}
dns_pid=
http_pid=
recovery_http_pid=
container_owned=0
volume_owned=0
image_id=unknown
result=fail
runtime=not-tested
ownership=not-tested
workload=not-tested
started=$(date -u +%FT%TZ)
case "$request_timeout" in ''|*[!0-9]*|0) exit 2 ;; esac
case "$network_mode" in bridge|private) ;; *) exit 2 ;; esac
case "$recovery" in 0|1) ;; *) exit 2 ;; esac
case "$policy:$recovery" in 0:0|0:1|1:0) ;; *) exit 2 ;; esac
case "$datasaver:$policy:$recovery" in 0:0:0|0:0:1|0:1:0|1:0:0) ;; *) exit 2 ;; esac
case "$metered:$datasaver:$policy:$recovery" in 0:0:0:0|0:0:0:1|0:0:1:0|0:1:0:0|1:0:0:0) ;; *) exit 2 ;; esac
case "$saver_policy:$metered:$datasaver:$policy:$recovery" in 0:0:0:0:0|0:0:0:0:1|0:0:0:1:0|0:0:1:0:0|0:1:0:0:0|1:0:0:0:0) ;; *) exit 2 ;; esac
case "$sleep_launch:$metered:$saver_policy" in 0:0:0|0:1:0|0:0:1|1:1:0|1:0:1) ;; *) exit 2 ;; esac
case "$output" in ''|/|.|..) exit 2 ;; esac
for command in docker go; do command -v "$command" >/dev/null 2>&1 || exit 1; done
case "${DOCKER_HOST:-unix:///var/run/docker.sock}" in unix://*) ;; *) exit 2 ;; esac
case "$(docker context inspect --format '{{.Endpoints.docker.Host}}')" in unix://*) ;; *) exit 2 ;; esac
if docker inspect "$container" >/dev/null 2>&1 || docker volume inspect "$volume" >/dev/null 2>&1; then
  printf '%s\n' 'error: DNS test resource already exists' >&2
  exit 1
fi
mkdir -p "$(dirname -- "$output")"
mkdir "$output" || { printf '%s\n' 'error: DNS evidence directory must be new' >&2; exit 1; }
output=$(CDPATH= cd -- "$output" && pwd)
finish() {
  status=$?
  trap - EXIT HUP INT TERM
  for pid in "$dns_pid" "$http_pid" "$recovery_http_pid"; do
    if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; wait "$pid" || true; fi
  done
  if [ "$container_owned" = 1 ]; then
    "$script_dir/container-evidence.sh" "$container" "$output/container" >"$output/capture.log" 2>&1 || status=1
  fi
  [ "$status" -eq 0 ] || result=fail
  cat >"$output/manifest.env" <<MANIFEST
ROYD_NETWORK_DNS_EVIDENCE_FORMAT=$format
NETWORK_SCOPE=$scope
NETWORK_MODE=$network_mode
METERED_SLEEP_BEFORE_LAUNCH=$sleep_launch
RESULT_STATUS=$result
RUNTIME_STATUS=$runtime
OCI_OWNERSHIP_STATUS=$ownership
WORKLOAD_STATUS=$workload
IMAGE=$image
IMAGE_ID=$image_id
TLS_STATUS=not-tested
STARTED_AT=$started
FINISHED_AT=$(date -u +%FT%TZ)
MANIFEST
  if [ -f "$output/assessment.env" ]; then
    # Only bounded fixture-produced status fields belong in the manifest.
    sed -n '/^OBSERVATION_STATUS=\(pass\|fail\)$/p; /^TRANSPORT_CONTROL_STATUS=\(pass\|fail\)$/p; /^SYSTEM_DNS_STATUS=\(pass\|fail\)$/p; /^FRAMEWORK_NETWORK_STATUS=\(pass\|fail\)$/p' "$output/assessment.env" >>"$output/manifest.env"
    sed -n '/^APP_PROCESS_STATUS=\(pass\|fail\)$/p; /^BASELINE_NETWORK_STATUS=\(pass\|fail\)$/p; /^NETWORK_LOSS_STATUS=\(pass\|fail\)$/p; /^NETWORK_RECOVERY_STATUS=\(pass\|fail\)$/p' "$output/assessment.env" >>"$output/manifest.env"
    sed -n '/^POLICY_\(OBSERVATION\|DENIAL\|CONTROL\|RESTORATION\|MAP\|SERVER\)_STATUS=\(pass\|fail\)$/p' "$output/assessment.env" >>"$output/manifest.env"
    sed -n '/^METERED_\(OBSERVATION\|BACKGROUND\|DENIAL\|CONTROL\|RESTORATION\|MAP\|SERVER\)_STATUS=\(pass\|fail\)$/p' "$output/assessment.env" >>"$output/manifest.env"
    sed -n '/^SAVER_\(OBSERVATION\|PROCESS_STATE\|DENIAL\|CONTROL\|RESTORATION\|MAP\|SERVER\)_STATUS=\(pass\|fail\)$/p' "$output/assessment.env" >>"$output/manifest.env"
  fi
  if [ -f "$output/datasaver-assessment.env" ]; then
    sed -n '/^DATASAVER_\(COMMAND\|ACTIVATION\|RESTORATION\|APP_CONTROL\)_STATUS=\(pass\|fail\|not-tested\)$/p; /^DATASAVER_ENFORCEMENT_STATUS=not-tested$/p' "$output/datasaver-assessment.env" >>"$output/manifest.env"
  fi
  if [ "$container_owned" = 1 ]; then docker rm -f "$container" >/dev/null 2>&1 || true; fi
  if [ "$volume_owned" = 1 ]; then docker volume rm "$volume" >/dev/null 2>&1 || true; fi
  if [ "$network_owned" = 1 ]; then docker network rm "$network" >/dev/null 2>&1 || true; fi
  exit "$status"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM
image_id=$(docker image inspect --format '{{.Id}}' "$image")
if [ "$network_mode" = private ]; then
  network=$container-net
  if docker network inspect "$network" >/dev/null 2>&1; then exit 1; fi
  docker network create "$network" >"$output/network.log"
  network_owned=1
fi
gateway=$(docker network inspect "$network" --format '{{(index .IPAM.Config 0).Gateway}}')
expected_resolver=$gateway
if [ "$network_mode" = private ]; then expected_resolver=127.0.0.11; fi
ROYD_NETWORK_DNS_POLICY=$((policy | metered | saver_policy)) "$build_runner" "$output/build" >"$output/build.log" 2>&1
"$output/build/dns-fixture" -listen "$gateway:53" >"$output/dns-server.log" 2>&1 &
dns_pid=$!
"$output/build/http-fixture" -listen "$gateway:0" >"$output/http-server.log" 2>&1 &
http_pid=$!
attempt=0
until grep -Fxq DNS_READY=1 "$output/dns-server.log" && grep -q '^URL=' "$output/http-server.log"; do
  kill -0 "$dns_pid"; kill -0 "$http_pid"
  attempt=$((attempt + 1)); [ "$attempt" -lt 10 ]; sleep 1
done
url=$(sed -n 's/^URL=//p' "$output/http-server.log")
recovery_url=
if [ "$recovery" = 1 ]; then
  "$output/build/http-fixture" -listen "$gateway:0" >"$output/recovery-http-server.log" 2>&1 &
  recovery_http_pid=$!
  attempt=0
  until grep -q '^URL=' "$output/recovery-http-server.log"; do
    kill -0 "$recovery_http_pid"
    attempt=$((attempt + 1)); [ "$attempt" -lt 10 ]; sleep 1
  done
  recovery_url=$(sed -n 's/^URL=//p' "$output/recovery-http-server.log")
  [ "$url" != "$recovery_url" ]
fi
docker volume create "$volume" >"$output/volume.log"
volume_owned=1
security_args=$("$script_dir/security-args.sh" privileged)
container_args=$("$script_dir/container-args.sh")
profile_args=$(ROYD_RESOURCE_PROFILE=low-memory "$script_dir/profile.sh" default)
# Word splitting is intentional for repository-generated arguments.
# shellcheck disable=SC2086
docker create $security_args $container_args --network "$network" --dns "$gateway" --name "$container" \
  --label org.royd.test=network-dns --label "org.royd.test.owner=$container" \
  -v "$volume:/data" "$image_id" $profile_args >"$output/create.log"
container_owned=1
docker start "$container" >>"$output/create.log"
ROYD_BOOT_WAIT_MARKER='ROYD: using delegated cgroup v2 subtree' \
  "${ROYD_NETWORK_DNS_WAIT_RUNNER:-$script_dir/wait-for-boot.sh}" "$container" "${ROYD_BOOT_TIMEOUT:-180}" >"$output/boot.log" 2>&1
"${ROYD_NETWORK_DNS_HEALTH_RUNNER:-$script_dir/wait-for-health.sh}" "$container" "${ROYD_HEALTH_TIMEOUT:-240}" >"$output/health.log" 2>&1
"${ROYD_NETWORK_DNS_SECURITY_RUNNER:-$script_dir/assert-security.sh}" "$container" privileged >"$output/security.log" 2>&1
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
docker cp "$output/build/probe.apk" "$container:/data/local/tmp/royd-network-probe.apk"
docker exec "$container" timeout 30 pm install -t /data/local/tmp/royd-network-probe.apk >"$output/install.log" 2>&1
grep -Fxq Success "$output/install.log"
workload=fail
if [ "$metered" = 1 ] || [ "$saver_policy" = 1 ]; then
  "$script_dir/network-metered-workload.sh" "$container" "$output" "$gateway" "$url" >"$output/workload.log" 2>&1 && workload=pass
elif [ "$policy" = 1 ]; then
  "$script_dir/network-policy-workload.sh" "$container" "$output" "$gateway" "$url" >"$output/workload.log" 2>&1 && workload=pass
elif [ "$recovery" = 1 ]; then
  "$script_dir/network-recovery-workload.sh" "$container" "$output" "$gateway" "$url" "$recovery_url" >"$output/workload.log" 2>&1 && workload=pass
else
docker exec "$container" timeout 30 am start -W -n org.royd.networkprobe/.NetworkProbe \
  --es host royd-probe.test --es dns "$gateway" --es url "$url" >"$output/launch.log" 2>&1
grep -Fxq 'Status: ok' "$output/launch.log"
grep -Fxq 'Activity: org.royd.networkprobe/.NetworkProbe' "$output/launch.log"
result_file=/data/user/0/org.royd.networkprobe/files/result.json
attempt=0
until docker exec "$container" timeout 5 test -s "$result_file"; do
  attempt=$((attempt + 1)); [ "$attempt" -lt "$request_timeout" ]; sleep 1
done
docker exec "$container" cat "$result_file" >"$output/observation.json"
app_pid=$(docker exec "$container" pidof org.royd.networkprobe)
case "$app_pid" in ''|*[!0-9]*) exit 1 ;; esac
app_uid=$(docker exec "$container" stat -c %u "/proc/$app_pid")
case "$app_uid" in ''|*[!0-9]*) exit 1 ;; esac
[ "$app_uid" -ge 10000 ]
[ "$app_uid" = "$(docker exec "$container" stat -c %u "$result_file")" ]
printf 'APP_PID=%s\nAPP_UID=%s\nSYSTEM_SERVER=%s\nURL=%s\n' "$app_pid" "$app_uid" "$system_before" "$url" >"$output/application.env"
# Result writing and the UI update run on different threads.
sleep 2
docker exec "$container" logcat -d -s RoydNetworkProbe:I '*:S' >"$output/application.log" 2>&1
docker exec "$container" screencap -p >"$output/application.png"
workload=pass
fi
if [ "$datasaver" = 1 ]; then
  workload=fail
  "$script_dir/network-datasaver-workload.sh" "$container" "$output" "$gateway" "$expected_resolver" "$url" "$app_uid" >"$output/datasaver-workload.log" 2>&1 && workload=pass
fi
for service in connectivity dnsresolver netd; do
  docker exec "$container" timeout 15 dumpsys "$service" >"$output/$service.log" 2>&1
done
docker exec "$container" timeout 15 dumpsys package org.royd.networkprobe >"$output/package.log" 2>&1
docker exec "$container" sh -c 'cat /etc/resolv.conf; ip rule; ip route show table all' >"$output/routes-dns.log" 2>&1
# Assess even if the post-workload gate fails, retaining independent failure causes.
runtime=pass
ROYD_HAL_PROFILE=graphical ROYD_GRAPHICS_BACKEND=software ROYD_RESOURCE_PROFILE=low-memory \
  "$assert_runner" "$container" >"$output/after-runtime.log" 2>&1 || runtime=fail
[ "$system_before" = "$(docker exec "$container" pidof system_server)" ] || runtime=fail
if [ "$saver_policy" = 1 ] || [ "$datasaver" = 1 ]; then
  if docker exec "$container" timeout 15 dumpsys tethering >"$output/tethering.log" 2>&1; then
    # A successful activation workload must exercise the bounded idle-stop path, not
    # silently avoid its broadcast. Packet success never replaces full runtime checks.
    if [ "$workload" = pass ]; then
      [ "$(grep -Fc 'ROYD: skipping idle tethering stops for unadvertised container hardware' "$output/tethering.log")" -eq 1 ] || runtime=fail
      awk '
        /^[[:space:]]*Tether state:$/ {sections++;inside=1;next}
        inside && /^[[:space:]]*Hardware offload:$/ {inside=0;ends++;next}
        inside && /^[[:space:]]*Upstream wanted: false$/ {idle++;next}
        inside && /^[[:space:]]*Current upstream interface\(s\): null$/ {upstream++;next}
        inside && $0 !~ /^[[:space:]]*$/ {unexpected=1}
        END {exit !(sections==1 && ends==1 && idle==1 && upstream==1 && !unexpected)}
      ' "$output/tethering.log" || runtime=fail
    fi
  else
    runtime=fail
  fi
fi
if [ "$recovery" = 1 ] || [ "$policy" = 1 ] || [ "$datasaver" = 1 ] || [ "$metered" = 1 ] || [ "$saver_policy" = 1 ]; then
  docker inspect --format '{{.Id}} {{.State.StartedAt}} {{.State.Running}} {{.RestartCount}} {{.State.OOMKilled}}' "$container" >"$output/runtime-after.txt"
  cmp -s "$output/runtime-before.txt" "$output/runtime-after.txt" || runtime=fail
fi
snapshot_oci >"$output/oci-after.log"
ownership=pass
cmp -s "$output/oci-before.log" "$output/oci-after.log" || ownership=fail
assessment=0
if [ "$saver_policy" = 1 ]; then
  "$output/build/dns-fixture" -saver "$output" -expected "$gateway" -resolver "$expected_resolver" -url "$url" \
    >"$output/assessment.env" 2>"$output/assessment.log" || assessment=$?
elif [ "$metered" = 1 ]; then
  "$output/build/dns-fixture" -metered "$output" -expected "$gateway" -resolver "$expected_resolver" -url "$url" \
    >"$output/assessment.env" 2>"$output/assessment.log" || assessment=$?
elif [ "$policy" = 1 ]; then
  "$output/build/dns-fixture" -policy "$output" -expected "$gateway" -resolver "$expected_resolver" -url "$url" \
    >"$output/assessment.env" 2>"$output/assessment.log" || assessment=$?
elif [ "$recovery" = 1 ]; then
  app_uid=$(sed -n 's/^APP_UID=//p' "$output/application.env" 2>/dev/null || true)
  app_pid=$(sed -n 's/^APP_PID=//p' "$output/application.env" 2>/dev/null || true)
  "$output/build/dns-fixture" -recovery "$output" -expected "$gateway" -resolver "$expected_resolver" \
    -url "$url" -recovery-url "$recovery_url" -uid "${app_uid:-0}" -pid "${app_pid:-0}" >"$output/assessment.env" 2>"$output/assessment.log" || assessment=$?
else
  "$output/build/dns-fixture" -result "$output/observation.json" -expected "$gateway" -resolver "$expected_resolver" >"$output/assessment.env" || assessment=$?
fi
if [ "$assessment" -ne 0 ] || [ "$runtime" != pass ] || [ "$ownership" != pass ] || [ "$workload" != pass ]; then exit 1; fi
result=pass
printf 'Android 15 application DNS and network-state test passed: %s\n' "$output"
