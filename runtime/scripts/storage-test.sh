#!/bin/sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
image=${1:-${ROYD_IMAGE:-$($script_dir/default-image.sh standard x86_64)}}
output=${ROYD_STORAGE_OUTPUT_DIR:-$root/.work/storage-$(date -u +%Y%m%dT%H%M%SZ)-$$}
container=royd-storage-$$
volume=$container-data
owned=0
volume_owned=0
result=fail
api=not-tested
ui=not-tested
runtime=not-tested
image_id=unknown
build_runner=${ROYD_STORAGE_BUILD_RUNNER:-$script_dir/storage-build.sh}
assert_runner=${ROYD_STORAGE_ASSERT_RUNNER:-$script_dir/assert-runtime.sh}
for command in docker jq timeout; do command -v "$command" >/dev/null 2>&1; done
case "$output" in ''|/|.|..) exit 2 ;; esac
if docker inspect "$container" >/dev/null 2>&1 || docker volume inspect "$volume" >/dev/null 2>&1; then exit 1; fi
mkdir -p "$(dirname -- "$output")"
mkdir "$output" || { printf '%s\n' 'error: storage evidence directory must be new' >&2; exit 1; }
output=$(CDPATH= cd -- "$output" && pwd)
finish() {
  status=$?
  trap - EXIT HUP INT TERM
  if [ "$owned" = 1 ]; then
    "$script_dir/container-evidence.sh" "$container" "$output/container" >"$output/capture.log" 2>&1 || status=1
  fi
  [ "$status" -eq 0 ] || result=fail
  printf 'ROYD_STORAGE_EVIDENCE_FORMAT=1\nRESULT_STATUS=%s\nAPI_STATUS=%s\nSETTINGS_UI_STATUS=%s\nRUNTIME_STATUS=%s\nIMAGE_ID=%s\nOUTER_EXIT_STATUS=%s\n' \
    "$result" "$api" "$ui" "$runtime" "$image_id" "$status" >"$output/manifest.env"
  if [ "$owned" = 1 ]; then docker rm -f "$container" >/dev/null; fi
  if [ "$volume_owned" = 1 ]; then docker volume rm "$volume" >/dev/null; fi
  exit "$status"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM
image_id=$(docker image inspect --format '{{.Id}}' "$image")
"$build_runner" "$output/build" >"$output/build.log" 2>&1
docker volume create "$volume" >"$output/volume.log"
volume_owned=1
security_args=$("$script_dir/security-args.sh" privileged)
container_args=$("$script_dir/container-args.sh")
profile_args=$(ROYD_RESOURCE_PROFILE=low-memory "$script_dir/profile.sh" default)
# Word splitting is limited to repository-generated arguments.
# shellcheck disable=SC2086
docker create $security_args $container_args --name "$container" \
  --label org.royd.test=storage --label "org.royd.test.owner=$container" \
  -v "$volume:/data" "$image_id" $profile_args >"$output/create.log"
owned=1
docker start "$container" >>"$output/create.log"
ROYD_BOOT_WAIT_MARKER='ROYD: using delegated cgroup v2 subtree' \
  "${ROYD_STORAGE_WAIT_RUNNER:-$script_dir/wait-for-boot.sh}" "$container" 180 >"$output/boot.log" 2>&1
"${ROYD_STORAGE_HEALTH_RUNNER:-$script_dir/wait-for-health.sh}" "$container" 240 >"$output/health.log" 2>&1
"${ROYD_STORAGE_SECURITY_RUNNER:-$script_dir/assert-security.sh}" "$container" privileged >"$output/security.log" 2>&1
[ "$(docker exec "$container" getprop ro.build.version.sdk)" = 35 ]
ROYD_HAL_PROFILE=graphical ROYD_GRAPHICS_BACKEND=software ROYD_RESOURCE_PROFILE=low-memory \
  "$assert_runner" "$container" >"$output/before-runtime.log" 2>&1
snapshot() { docker inspect --format '{{.Id}} {{.State.StartedAt}} {{.State.Running}} {{.RestartCount}} {{.State.OOMKilled}}' "$container"; }
numeric() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; }
snapshot >"$output/identity-before.txt"
system_before=$(docker exec "$container" pidof system_server)
numeric "$system_before"
docker exec "$container" stat -f -c '%b %S' /data >"$output/data-blocks.txt"
set -- $(cat "$output/data-blocks.txt")
[ "$#" -eq 2 ]; numeric "$1"; numeric "$2"
pool_bytes=$(($1 * $2))
[ "$pool_bytes" -gt 0 ]
docker exec "$container" sh -c 'stat -f / /data /system; cat /proc/self/mountinfo' >"$output/filesystems.log"
docker cp "$output/build/probe.apk" "$container:/data/local/tmp/royd-storage-probe.apk"
docker exec "$container" timeout 30 pm install -t /data/local/tmp/royd-storage-probe.apk >"$output/install.log" 2>&1
grep -Fxq Success "$output/install.log"
api=fail
first_pid=
first_uid=
for round in 1 2; do
  docker exec "$container" timeout 20 am start -W -n org.royd.storageprobe/.StorageProbe --ei round "$round" >"$output/launch-$round.log" 2>&1
  grep -Fxq 'Status: ok' "$output/launch-$round.log"
  file=/data/user/0/org.royd.storageprobe/files/result-$round.json
  attempt=0
  until docker exec "$container" test -s "$file"; do
    attempt=$((attempt+1)); [ "$attempt" -lt 30 ]; sleep 1
  done
  docker exec "$container" cat "$file" >"$output/result-$round.json"
  pid=$(docker exec "$container" pidof org.royd.storageprobe)
  numeric "$pid"
  uid=$(docker exec "$container" stat -c %u "/proc/$pid")
  numeric "$uid"; [ "$uid" -ge 10000 ]
  [ "$uid" = "$(docker exec "$container" stat -c %u "$file")" ]
  "$script_dir/storage-assess.sh" "$output/result-$round.json" "$uid" "$pid" "$pool_bytes" "$round" >"$output/assessment-$round.log"
  if [ "$round" = 1 ]; then first_pid=$pid; first_uid=$uid
  else [ "$uid" = "$first_uid" ] && [ "$pid" != "$first_pid" ]; fi
  docker exec "$container" am force-stop org.royd.storageprobe >"$output/stop-$round.log" 2>&1
  [ -z "$(docker exec "$container" pidof org.royd.storageprobe || true)" ]
done
api=pass
docker exec "$container" timeout 15 dumpsys package org.royd.storageprobe >"$output/package.log"
docker exec "$container" timeout 15 dumpsys mount >"$output/mount.log"
grep -Fq "Internal storage (null) total size: $pool_bytes (" "$output/mount.log"
ui=fail
settings_before=$(docker exec "$container" pidof com.android.settings)
numeric "$settings_before"
docker exec "$container" input keyevent KEYCODE_WAKEUP
docker exec "$container" wm dismiss-keyguard
docker exec "$container" timeout 15 dumpsys power >"$output/storage-power-before.log"
docker exec "$container" timeout 20 am start -W -a android.settings.INTERNAL_STORAGE_SETTINGS >"$output/settings-launch.log" 2>&1
grep -Fxq 'Status: ok' "$output/settings-launch.log"
# A programmatic launch does not renew the display inactivity timer. Use normal
# touch input and retain proof that it refreshed activity on this owned instance.
docker exec "$container" input swipe 270 800 270 400 200
docker exec "$container" timeout 15 dumpsys power >"$output/storage-power-after.log"
grep -Eq '^[[:space:]]*mWakefulness=Awake$' "$output/storage-power-after.log"
activity_time() { sed -n 's/^[[:space:]]*mLastUserActivityTime(excludingAttention)=\([0-9][0-9]*\).*$/\1/p' "$1"; }
before_activity=$(activity_time "$output/storage-power-before.log")
after_activity=$(activity_time "$output/storage-power-after.log")
numeric "$before_activity"; numeric "$after_activity"
[ "$after_activity" -gt "$before_activity" ]
# Give asynchronous volume-size loaders time to complete; a launch response is not success.
sleep 15
docker exec "$container" timeout 15 dumpsys activity activities >"$output/settings-activities.log"
grep -Eq 'topResumedActivity=.*com\.android\.settings/\.Settings[$]StorageDashboardActivity' "$output/settings-activities.log"
[ "$settings_before" = "$(docker exec "$container" pidof com.android.settings)" ]
docker exec "$container" screencap -p >"$output/settings-storage.png"
docker logs --timestamps "$container" >"$output/workload-container.log" 2>&1
if grep -Eq 'FATAL EXCEPTION|Fatal signal|am_crash|No mount point entry for /data' "$output/workload-container.log"; then exit 1; fi
[ "$(grep -Fc 'ROYD: reporting /data filesystem capacity for container storage' "$output/workload-container.log")" -eq 1 ]
ui=pass
runtime=fail
ROYD_HAL_PROFILE=graphical ROYD_GRAPHICS_BACKEND=software ROYD_RESOURCE_PROFILE=low-memory \
  "$assert_runner" "$container" >"$output/after-runtime.log" 2>&1
[ "$system_before" = "$(docker exec "$container" pidof system_server)" ]
snapshot >"$output/identity-after.txt"
cmp "$output/identity-before.txt" "$output/identity-after.txt"
runtime=pass
result=pass
printf 'Android 15 storage API and Settings test passed: %s\n' "$output"
