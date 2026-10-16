#!/bin/sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
image=${1:-${ROYD_IMAGE:-$($script_dir/default-image.sh standard x86_64)}}
output=${ROYD_NETWORK_OUTPUT_DIR:-$repo_root/.work/network-http-$(date -u +%Y%m%dT%H%M%SZ)-$$}
container=royd-network-http-$$
volume=$container-data
wait_runner=${ROYD_NETWORK_WAIT_RUNNER:-$script_dir/wait-for-boot.sh}
health_runner=${ROYD_NETWORK_HEALTH_RUNNER:-$script_dir/wait-for-health.sh}
assert_runner=${ROYD_NETWORK_ASSERT_RUNNER:-$script_dir/assert-runtime.sh}
security_runner=${ROYD_NETWORK_SECURITY_RUNNER:-$script_dir/assert-security.sh}
request_timeout=${ROYD_NETWORK_REQUEST_TIMEOUT:-30}
boot_timeout=${ROYD_BOOT_TIMEOUT:-180}
server_pid=
container_owned=0
volume_owned=0
image_id=unknown
default_network=unknown
result=fail
started=$(date -u +%FT%TZ)
case "$request_timeout" in ''|*[!0-9]*|0) exit 2 ;; esac
case "$output" in ''|/|.|..) exit 2 ;; esac
for command in docker go; do command -v "$command" >/dev/null 2>&1 || { printf 'error: %s is required\n' "$command" >&2; exit 1; }; done
case "${DOCKER_HOST:-unix:///var/run/docker.sock}" in unix://*) ;; *) exit 2 ;; esac
case "$(docker context inspect --format '{{.Endpoints.docker.Host}}')" in unix://*) ;; *) exit 2 ;; esac
if docker inspect "$container" >/dev/null 2>&1 || docker volume inspect "$volume" >/dev/null 2>&1; then
  printf '%s\n' 'error: network test resource already exists' >&2
  exit 1
fi
mkdir -p "$(dirname -- "$output")"
mkdir "$output" || { printf '%s\n' 'error: network evidence directory must be new' >&2; exit 1; }

finish() {
  status=$?
  trap - EXIT HUP INT TERM
  if [ -n "$server_pid" ]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" || true
  fi
  if [ "$container_owned" = 1 ]; then
    if ! "$script_dir/container-evidence.sh" "$container" "$output/container" >"$output/capture.log" 2>&1; then
      status=1
    fi
  fi
  [ "$status" -eq 0 ] || result=fail
  cat >"$output/manifest.env" <<MANIFEST
ROYD_NETWORK_HTTP_EVIDENCE_FORMAT=1
NETWORK_SCOPE=webview-ipv4-literal-http
RESULT_STATUS=$result
IMAGE=$image
IMAGE_ID=$image_id
FRAMEWORK_DEFAULT_NETWORK=$default_network
DNS_STATUS=not-tested
TLS_STATUS=not-tested
STARTED_AT=$started
FINISHED_AT=$(date -u +%FT%TZ)
MANIFEST
  if [ "$container_owned" = 1 ]; then docker rm -f "$container" >/dev/null 2>&1 || true; fi
  if [ "$volume_owned" = 1 ]; then docker volume rm "$volume" >/dev/null 2>&1 || true; fi
  exit "$status"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM

image_id=$(docker image inspect --format '{{.Id}}' "$image")
gateway=$(docker network inspect bridge --format '{{(index .IPAM.Config 0).Gateway}}')
go build -o "$output/http-server" "$repo_root/runtime/tests/network-http/server.go"
"$output/http-server" -listen "$gateway:0" >"$output/http-server.log" 2>&1 &
server_pid=$!
attempt=0
until grep -q '^URL=' "$output/http-server.log"; do
  kill -0 "$server_pid"
  attempt=$((attempt + 1))
  [ "$attempt" -lt 10 ]
  sleep 1
done
url=$(sed -n 's/^URL=//p' "$output/http-server.log")
docker volume create "$volume" >"$output/volume.log"
volume_owned=1
security_args=$("$script_dir/security-args.sh" privileged)
container_args=$("$script_dir/container-args.sh")
profile_args=$(ROYD_RESOURCE_PROFILE=low-memory "$script_dir/profile.sh" default)
# Word splitting is intentional for repository-generated arguments.
# shellcheck disable=SC2086
docker create $security_args $container_args --network bridge --name "$container" \
  -v "$volume:/data" "$image_id" $profile_args >"$output/create.log"
container_owned=1
docker start "$container" >>"$output/create.log"
"$wait_runner" "$container" "$boot_timeout" >"$output/boot.log" 2>&1
"$health_runner" "$container" "${ROYD_HEALTH_TIMEOUT:-240}" >"$output/health.log" 2>&1
"$security_runner" "$container" privileged >"$output/security.log" 2>&1
[ "$(docker exec "$container" getprop ro.build.version.sdk)" = 35 ]
ROYD_HAL_PROFILE=graphical ROYD_GRAPHICS_BACKEND=software ROYD_RESOURCE_PROFILE=low-memory \
  "$assert_runner" "$container" >"$output/before-runtime.log" 2>&1
system_before=$(docker exec "$container" pidof system_server)
case "$system_before" in ''|*[!0-9]*) exit 1 ;; esac
docker exec "$container" timeout 15 dumpsys connectivity >"$output/connectivity.log" 2>&1
default_network=$(sed -n 's/^Active default network: //p' "$output/connectivity.log" | head -n 1)
case "$default_network" in none) ;; ''|*[!0-9]*) default_network=unknown ;; esac
docker exec "$container" timeout 15 dumpsys dnsresolver >"$output/dnsresolver.log" 2>&1
docker exec "$container" sh -c 'ip rule; ip route show table all; cat /etc/resolv.conf' >"$output/routes-dns.log" 2>&1
docker exec "$container" timeout 15 am force-stop org.chromium.webview_shell
docker exec "$container" timeout 30 am start -W \
  -n org.chromium.webview_shell/.WebViewBrowserActivity -d "$url" >"$output/launch.log" 2>&1
grep -Fxq 'Status: ok' "$output/launch.log"
grep -Fxq 'Activity: org.chromium.webview_shell/.WebViewBrowserActivity' "$output/launch.log"
app_pid=$(docker exec "$container" pidof org.chromium.webview_shell)
case "$app_pid" in ''|*[!0-9]*) exit 1 ;; esac
app_uid=$(docker exec "$container" stat -c %u "/proc/$app_pid")
case "$app_uid" in ''|*[!0-9]*) exit 1 ;; esac
[ "$app_uid" -ge 10000 ]
printf 'APP_PID=%s\nAPP_UID=%s\nSYSTEM_SERVER=%s\nURL=%s\n' "$app_pid" "$app_uid" "$system_before" "$url" >"$output/application.env"
attempt=0
until grep -Fxq 'WEBVIEW_CALLBACK=pass' "$output/http-server.log"; do
  kill -0 "$server_pid"
  attempt=$((attempt + 1))
  if [ "$attempt" -ge "$request_timeout" ]; then
    printf '%s\n' 'error: application HTTP callback was not observed' >&2
    exit 1
  fi
  sleep 1
done
grep -Fxq 'WEBVIEW_PAGE=pass' "$output/http-server.log"
# Allow the successful callback and its DOM update to reach the display.
sleep 2
docker exec "$container" screencap -p >"$output/webview.png"
ROYD_HAL_PROFILE=graphical ROYD_GRAPHICS_BACKEND=software ROYD_RESOURCE_PROFILE=low-memory \
  "$assert_runner" "$container" >"$output/after-runtime.log" 2>&1
[ "$system_before" = "$(docker exec "$container" pidof system_server)" ]
result=pass
printf 'Android 15 literal-IP WebView HTTP test passed: %s\n' "$output"
