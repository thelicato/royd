#!/bin/sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
image=${1:-${ROYD_IMAGE:-$($script_dir/default-image.sh standard x86_64)}}
output=${ROYD_MEDIA_OUTPUT_DIR:-$root/.work/mediaextractor-$(date -u +%Y%m%dT%H%M%SZ)-$$}
container=royd-mediaextractor-$$
volume=$container-data
owned=0 volume_owned=0 pre=0
api=not-tested ui=not-tested policy=not-tested runtime=not-tested
image_id=unknown
assert_runner=$script_dir/assert-runtime.sh
for command in docker jq timeout python3; do command -v "$command" >/dev/null 2>&1; done
case "$output" in ''|/|.|..) exit 2 ;; esac
if docker inspect "$container" >/dev/null 2>&1 || docker volume inspect "$volume" >/dev/null 2>&1; then exit 1; fi
mkdir -p "$(dirname -- "$output")"
mkdir "$output"
output=$(CDPATH= cd -- "$output" && pwd)
snapshot() { docker inspect --format '{{.Id}} {{.State.StartedAt}} {{.State.Running}} {{.RestartCount}} {{.State.OOMKilled}}' "$container"; }
numeric() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; }
runtime_check() {
  ROYD_HAL_PROFILE=graphical ROYD_GRAPHICS_BACKEND=software ROYD_RESOURCE_PROFILE=low-memory "$assert_runner" "$container"
}
finish() {
  status=$?
  trap - EXIT HUP INT TERM
  if [ "$pre" = 1 ]; then
    runtime=fail
    if runtime_check >"$output/after-runtime.log" 2>&1; then runtime=pass; else status=1; fi
    snapshot >"$output/identity-after.txt" || status=1
    cmp "$output/identity-before.txt" "$output/identity-after.txt" || status=1
    [ "$system_before" = "$(docker exec "$container" pidof system_server)" ] || status=1
    [ "$extractor_before" = "$(docker exec "$container" pidof media.extractor)" ] || status=1
  fi
  if [ "$owned" = 1 ]; then
    "$script_dir/container-evidence.sh" "$container" "$output/container" >"$output/capture.log" 2>&1 || status=1
  fi
  result=fail
  [ "$status" -ne 0 ] || result=pass
  printf 'ROYD_MEDIA_EVIDENCE_FORMAT=1\nRESULT_STATUS=%s\nAPI_STATUS=%s\nSETTINGS_UI_STATUS=%s\nPOLICY_STATUS=%s\nRUNTIME_STATUS=%s\nIMAGE_ID=%s\nCOMMAND_EXIT_STATUS=%s\n' \
    "$result" "$api" "$ui" "$policy" "$runtime" "$image_id" "$status" >"$output/manifest.env"
  if [ "$owned" = 1 ]; then docker rm -f "$container" >/dev/null; fi
  if [ "$volume_owned" = 1 ]; then docker volume rm "$volume" >/dev/null; fi
  printf 'Android 15 mediaextractor result: %s, evidence: %s\n' "$result" "$output"
  exit "$status"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM
image_id=$(docker image inspect --format '{{.Id}}' "$image")
"$script_dir/mediaextractor-build.sh" "$output/build" >"$output/build.log" 2>&1
docker volume create "$volume" >"$output/volume.log"
volume_owned=1
security_args=$("$script_dir/security-args.sh" privileged)
container_args=$("$script_dir/container-args.sh")
profile_args=$(ROYD_RESOURCE_PROFILE=low-memory "$script_dir/profile.sh" default)
# Splitting is limited to repository-generated arguments.
# shellcheck disable=SC2086
docker create $security_args $container_args --name "$container" \
  --label org.royd.test=mediaextractor --label "org.royd.test.owner=$container" \
  -v "$volume:/data" "$image_id" $profile_args >"$output/create.log"
owned=1
docker start "$container" >>"$output/create.log"
ROYD_BOOT_WAIT_MARKER='ROYD: using delegated cgroup v2 subtree' \
  "$script_dir/wait-for-boot.sh" "$container" 180 >"$output/boot.log" 2>&1
"$script_dir/wait-for-health.sh" "$container" 240 >"$output/health.log" 2>&1
"$script_dir/assert-security.sh" "$container" privileged >"$output/security.log" 2>&1
[ "$(docker exec "$container" getprop ro.build.version.sdk)" = 35 ]
runtime_check >"$output/before-runtime.log" 2>&1
system_before=$(docker exec "$container" pidof system_server)
extractor_before=$(docker exec "$container" pidof media.extractor)
numeric "$system_before"; numeric "$extractor_before"
snapshot >"$output/identity-before.txt"
pre=1
docker exec "$container" cat "/proc/$extractor_before/status" >"$output/extractor-before.status"
grep -Eq '^Uid:[[:space:]]+1040[[:space:]]+1040' "$output/extractor-before.status"
grep -Eq '^Seccomp:[[:space:]]+2$' "$output/extractor-before.status"
grep -Eq '^NoNewPrivs:[[:space:]]+1$' "$output/extractor-before.status"
docker cp "$output/build/probe.apk" "$container:/data/local/tmp/royd-media-probe.apk"
docker exec "$container" timeout 30 pm install -t /data/local/tmp/royd-media-probe.apk >"$output/install.log" 2>&1
grep -Fxq Success "$output/install.log"
api=fail
docker exec "$container" input keyevent KEYCODE_WAKEUP
docker exec "$container" wm dismiss-keyguard
docker exec "$container" timeout 20 am start -W -n org.royd.mediaprobe/.MediaProbe >"$output/launch.log" 2>&1
grep -Fxq 'Status: ok' "$output/launch.log"
file=/data/user/0/org.royd.mediaprobe/files/result.json
attempt=0
until docker exec "$container" test -s "$file"; do
  attempt=$((attempt+1)); [ "$attempt" -lt 45 ]; sleep 1
done
docker exec "$container" cat "$file" >"$output/observation.json"
pid=$(docker exec "$container" pidof org.royd.mediaprobe)
numeric "$pid"
uid=$(docker exec "$container" stat -c %u "/proc/$pid")
numeric "$uid"
[ "$uid" -ge 10000 ]
[ "$uid" = "$(docker exec "$container" stat -c %u "$file")" ]
printf 'APP_UID=%s\nAPP_PID=%s\nEXTRACTOR_PID=%s\n' "$uid" "$pid" "$extractor_before" >"$output/application.env"
"$script_dir/mediaextractor-assess.sh" "$output/observation.json" "$uid" "$pid" >"$output/assessment.log"
api=pass
docker exec "$container" timeout 15 dumpsys package org.royd.mediaprobe >"$output/package.log"
settings_before=$(docker exec "$container" pidof com.android.settings)
numeric "$settings_before"
ui=fail
for round in 1 2 3 4 5; do
  docker exec "$container" input keyevent KEYCODE_WAKEUP
  docker exec "$container" timeout 20 am start -W -a android.settings.SOUND_SETTINGS >"$output/sound-launch-$round.log" 2>&1
  grep -Fxq 'Status: ok' "$output/sound-launch-$round.log"
  sleep 3
  docker exec "$container" timeout 15 dumpsys activity activities >"$output/sound-activities-$round.log"
  grep -Eq 'topResumedActivity=.*com\.android\.settings/\.Settings[$]SoundSettingsActivity' "$output/sound-activities-$round.log"
  [ "$settings_before" = "$(docker exec "$container" pidof com.android.settings)" ]
  [ "$extractor_before" = "$(docker exec "$container" pidof media.extractor)" ]
  docker exec "$container" screencap -p >"$output/sound-$round.png"
  docker exec "$container" input keyevent KEYCODE_HOME
done
ui=pass
policy=fail
docker exec "$container" cat "/proc/$extractor_before/status" >"$output/extractor-after.status"
grep -Eq '^Seccomp:[[:space:]]+2$' "$output/extractor-after.status"
grep -Eq '^NoNewPrivs:[[:space:]]+1$' "$output/extractor-after.status"
docker logs --timestamps "$container" >"$output/workload-container.log" 2>&1
[ "$(grep -Fc 'ROYD: using sealed-memfd mediaextractor seccomp policy' "$output/workload-container.log")" -eq 1 ]
if grep -Eq 'FATAL EXCEPTION|Fatal signal|am_crash|blocked syscall: memfd_create|Service .mediaextractor.*received signal (6|31)([^0-9]|$)' "$output/workload-container.log"; then exit 1; fi
policy=pass
