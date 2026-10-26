#!/bin/sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
! grep -Eq 'uses-permission|sharedUserId|platform' "$root/runtime/tests/storage/AndroidManifest.xml"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
cat >"$tmp/good.json" <<'JSON'
{"status":"pass","done":true,"uid":10096,"pid":4001,"round":1,"readings":[{"filesystem_total":518933680128,"filesystem_available":1000000000,"stats_total":518933680128,"stats_free":1000000000},{"filesystem_total":518933680128,"filesystem_available":999000000,"stats_total":518933680128,"stats_free":999000000},{"filesystem_total":518933680128,"filesystem_available":998000000,"stats_total":518933680128,"stats_free":998000000}]}
JSON
"$script_dir/storage-assess.sh" "$tmp/good.json" 10096 4001 518933680128 1
for mutation in '.done=false' '.status="fail"' '.error="EINVAL"' '.uid=0' '.pid=3999' '.round=2' \
    '.readings=[]' '.readings |= .[:2]' '.readings[0].stats_total=2000000000000' \
    '.readings[1].stats_total=512000000000' '.readings[2].filesystem_total=0' \
    '.readings[1].stats_free=-1' '.readings[1].stats_free=2000000000000' \
    '.readings[1].filesystem_available="missing"' '.readings[1].filesystem_available=2000000000000' \
    '.readings={a:.readings[0],b:.readings[1],c:.readings[2]}'; do
  jq "$mutation" "$tmp/good.json" >"$tmp/bad.json"
  if "$script_dir/storage-assess.sh" "$tmp/bad.json" 10096 4001 518933680128 1 >"$tmp/result" 2>&1; then
    printf 'error: storage assessor accepted %s\n' "$mutation" >&2; exit 1
  fi
done
mkdir "$tmp/bin"
cat >"$tmp/bin/pass" <<'MOCK'
#!/bin/sh
exit 0
MOCK
cat >"$tmp/bin/build" <<'MOCK'
#!/bin/sh
mkdir "$1"
: >"$1/probe.apk"
MOCK
cat >"$tmp/bin/assert" <<'MOCK'
#!/bin/sh
count=0
[ ! -f "$MOCK_STATE/asserts" ] || count=$(cat "$MOCK_STATE/asserts")
count=$((count+1))
printf '%s\n' "$count" >"$MOCK_STATE/asserts"
[ "$MOCK_CASE:$count" != post_runtime_failure:2 ]
MOCK
cat >"$tmp/bin/sleep" <<'MOCK'
#!/bin/sh
exit 0
MOCK
cat >"$tmp/bin/docker" <<'MOCK'
#!/bin/sh
set -eu
printf '%s\n' "$*" >>"$MOCK_STATE/docker.log"
case "$1" in
  image) printf 'sha256:%064d\n' 1 ;;
  inspect)
    if [ "${2:-}" = --format ]; then
      if [ "$MOCK_CASE" = identity_changed ] && [ -f "$MOCK_STATE/settings" ]; then printf '%064d changed true 0 false\n' 2
      else printf '%064d start true 0 false\n' 2; fi
    else [ -f "$MOCK_STATE/container" ]; printf '%s\n' '[{"State":{"Running":true}}]'; fi ;;
  volume)
    case "$2" in inspect) [ "$MOCK_CASE" = existing_volume ] ;; create) : >"$MOCK_STATE/volume" ;; rm) rm "$MOCK_STATE/volume" ;; *) exit 99 ;; esac ;;
  create) : >"$MOCK_STATE/container" ;;
  start|cp) : ;;
  rm) rm "$MOCK_STATE/container" ;;
  logs)
    printf '%s\n' 'full container log'
    [ "$MOCK_CASE" != marker_missing ] || exit 0
    printf '%s\n' 'ROYD: reporting /data filesystem capacity for container storage'
    [ "$MOCK_CASE" != marker_duplicate ] || printf '%s\n' 'ROYD: reporting /data filesystem capacity for container storage'
    [ "$MOCK_CASE" != recovered_crash ] || printf '%s\n' 'am_crash: [100,0,com.android.settings,exception]'
    ;;
  exec)
    shift 2
    case "$*" in
      'getprop ro.build.version.sdk') printf '%s\n' 35 ;;
      'stat -f -c %b %S /data') printf '%s\n' '126692793 4096' ;;
      'stat -c %u '*) if [ "$MOCK_CASE" = privileged_uid ]; then printf '%s\n' 0; else printf '%s\n' 10096; fi ;;
      'pidof system_server')
        if [ "$MOCK_CASE" = system_replaced ] && [ -f "$MOCK_STATE/settings" ]; then printf '%s\n' 446
        else printf '%s\n' 445; fi ;;
      'pidof com.android.settings')
        if [ "$MOCK_CASE" = settings_replaced ] && [ -f "$MOCK_STATE/settings" ]; then printf '%s\n' 2000
        else printf '%s\n' 1368; fi ;;
      'pidof org.royd.storageprobe')
        [ -f "$MOCK_STATE/app" ] || exit 1
        if [ "$(cat "$MOCK_STATE/round")" = 1 ] || [ "$MOCK_CASE" = same_pid ]; then printf '%s\n' 4001; else printf '%s\n' 4002; fi ;;
      'timeout 30 pm install -t '*) printf '%s\n' Success ;;
      'timeout 20 am start -W -n '* )
        for round in "$@"; do :; done
        printf '%s\n' "$round" >"$MOCK_STATE/round"
        : >"$MOCK_STATE/app"
        printf '%s\n' 'Status: ok' ;;
      'test -s '*) [ "$MOCK_CASE" != missing_result ] ;;
      'cat /data/user/'*)
        round=$(cat "$MOCK_STATE/round"); pid=4001
        if [ "$round" != 1 ] && [ "$MOCK_CASE" != same_pid ]; then pid=4002; fi
        jq --argjson round "$round" --argjson pid "$pid" '.round=$round | .pid=$pid' "$MOCK_GOOD" >"$MOCK_STATE/observation.json"
        if [ "$MOCK_CASE" = bad_api ]; then jq '.readings[0].stats_total=2000000000000' "$MOCK_STATE/observation.json"
        else cat "$MOCK_STATE/observation.json"; fi ;;
      'am force-stop org.royd.storageprobe') rm "$MOCK_STATE/app" ;;
      'timeout 15 dumpsys mount') printf '%s\n' 'Internal storage (null) total size: 518933680128 (494893 MiB)' ;;
      'timeout 20 am start -W -a '*) : >"$MOCK_STATE/settings"; printf '%s\n' 'Status: ok' ;;
      'input keyevent KEYCODE_WAKEUP')
        [ "$MOCK_CASE" != wake_failure ]; : >"$MOCK_STATE/awake" ;;
      'wm dismiss-keyguard')
        [ -f "$MOCK_STATE/awake" ]; : >"$MOCK_STATE/unlocked" ;;
      'input swipe 270 800 270 400 200')
        [ "$MOCK_CASE" != touch_failure ]
        [ -f "$MOCK_STATE/awake" ] && [ -f "$MOCK_STATE/unlocked" ] && [ -f "$MOCK_STATE/settings" ]
        : >"$MOCK_STATE/touched" ;;
      'timeout 15 dumpsys power')
        activity=100
        if [ -f "$MOCK_STATE/touched" ] && [ "$MOCK_CASE" != no_user_activity ]; then activity=200; fi
        if [ -f "$MOCK_STATE/touched" ] && [ "$MOCK_CASE" = asleep_after_touch ]; then wakefulness=Asleep
        else wakefulness=Awake; fi
        printf '  mWakefulness=%s\n mLastUserActivityTime(excludingAttention)=%s\n' "$wakefulness" "$activity" ;;
      'timeout 15 dumpsys activity activities')
        if [ "$MOCK_CASE" = wrong_activity ]; then printf '%s\n' 'topResumedActivity=com.android.settings/.Settings$MyDeviceInfoActivity'
        else printf '%s\n' 'topResumedActivity=com.android.settings/.Settings$StorageDashboardActivity'; fi ;;
      'timeout 15 dumpsys package '*|'sh -c '*|'screencap -p') printf '%s\n' evidence ;;
      *) printf 'unexpected Docker call: %s\n' "$*" >&2; exit 99 ;;
    esac ;;
  *) exit 99 ;;
esac
MOCK
chmod +x "$tmp/bin/"*
for mode in good bad_api recovered_crash marker_missing marker_duplicate settings_replaced wrong_activity \
    post_runtime_failure system_replaced identity_changed privileged_uid same_pid missing_result \
    wake_failure touch_failure no_user_activity asleep_after_touch \
    existing_volume existing_container existing_evidence; do
  state=$tmp/$mode
  mkdir "$state"
  case "$mode" in
    existing_volume) : >"$state/volume" ;;
    existing_container) : >"$state/container" ;;
    existing_evidence) mkdir "$state/evidence"; : >"$state/evidence/preserve" ;;
  esac
  status=0
  PATH="$tmp/bin:$PATH" MOCK_STATE="$state" MOCK_CASE="$mode" MOCK_GOOD="$tmp/good.json" \
    ROYD_STORAGE_OUTPUT_DIR="$state/evidence" ROYD_STORAGE_BUILD_RUNNER="$tmp/bin/build" \
    ROYD_STORAGE_WAIT_RUNNER="$tmp/bin/pass" ROYD_STORAGE_HEALTH_RUNNER="$tmp/bin/pass" \
    ROYD_STORAGE_SECURITY_RUNNER="$tmp/bin/pass" ROYD_STORAGE_ASSERT_RUNNER="$tmp/bin/assert" \
    "$script_dir/storage-test.sh" royd:test >"$state/result.log" 2>&1 || status=$?
  if [ "$mode" = good ]; then
    [ "$status" -eq 0 ]; grep -Fxq RESULT_STATUS=pass "$state/evidence/manifest.env"
    for field in API SETTINGS_UI RUNTIME; do grep -Fxq "${field}_STATUS=pass" "$state/evidence/manifest.env"; done
    [ "$(cat "$state/asserts")" = 2 ]
    grep -Eq '^create .*sha256:0*1 royd.width=540' "$state/docker.log"
  elif [ "$mode" = existing_volume ] || [ "$mode" = existing_container ] || [ "$mode" = existing_evidence ]; then
    [ "$status" -ne 0 ]; ! grep -Eq '^(create|rm|volume (create|rm))' "$state/docker.log"
  else
    [ "$status" -ne 0 ]; grep -Fxq RESULT_STATUS=fail "$state/evidence/manifest.env"
    grep -Fq 'full container log' "$state/evidence/container/container.log"
  fi
  case "$mode" in
    existing_volume) [ -f "$state/volume" ] ;;
    existing_container) [ -f "$state/container" ] ;;
    existing_evidence) [ -f "$state/evidence/preserve" ] ;;
    *) [ ! -f "$state/container" ] && [ ! -f "$state/volume" ] ;;
  esac
done
printf '%s\n' 'Storage API assessment and owned UI/runtime orchestration contracts passed'
