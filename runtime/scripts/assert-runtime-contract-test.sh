#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

cat > "$tmp/docker" <<'MOCK'
#!/bin/sh
set -eu

case "$1" in
  inspect)
    exit 0
    ;;
  exec)
    shift
    container=$1
    shift
    if [ "$1" = pidof ] && [ "$2" = audioserver ]; then
      printf '%s\n' "${MOCK_AUDIO_PID-237}"
      exit 0
    fi
    if [ "$1" = getprop ]; then
      property=$2
      case "$property" in
        ro.build.version.sdk) value=$MOCK_SDK ;;
        sys.boot_completed) value=1 ;;
        sys.royd.framework_ready)
          [ "${MOCK_BAD_FRAMEWORK_READY:-0}" = 1 ] && value=0 || value=1
          ;;
        ro.config.low_ram)
          if [ "${ROYD_RESOURCE_PROFILE:-low-memory}" = performance ]; then
            value=false
          else
            value=true
          fi
          ;;
        ro.config.per_app_memcg)
          [ "${MOCK_BAD_PER_APP_MEMCG:-0}" = 1 ] && value=false || value=true
          ;;
        ro.vendor.royd.resource_profile)
          if [ "${MOCK_BAD_RESOURCE_PROFILE:-0}" = 1 ]; then
            value=low-memory
          else
            value=${ROYD_RESOURCE_PROFILE:-low-memory}
          fi
          ;;
        dalvik.vm.heapstartsize)
          [ "${ROYD_RESOURCE_PROFILE:-low-memory}" = performance ] && value=8m || value=5m
          ;;
        dalvik.vm.heapgrowthlimit)
          [ "${ROYD_RESOURCE_PROFILE:-low-memory}" = performance ] && value=192m || value=48m
          ;;
        dalvik.vm.heapsize)
          [ "${ROYD_RESOURCE_PROFILE:-low-memory}" = performance ] && value=512m || value=128m
          ;;
        dalvik.vm.heaptargetutilization) value=0.75 ;;
        dalvik.vm.heapminfree) value=512k ;;
        dalvik.vm.heapmaxfree)
          [ "${ROYD_RESOURCE_PROFILE:-low-memory}" = performance ] && value=8m || value=2m
          ;;
        init.svc.royd-logcat|init.svc.adbd) value=running ;;
        init.svc.netd)
          [ "${MOCK_BAD_NETD:-0}" = 1 ] && value=restarting || value=running
          ;;
        init.svc.statsd)
          [ "${MOCK_BAD_STATSD:-0}" = 1 ] && value=restarting || value=running
          ;;
        init.svc.lmkd)
          [ "${MOCK_BAD_LMKD:-0}" = 1 ] && value=restarting || value=running
          ;;
        service.sf.present_timestamp)
          [ "${MOCK_BAD_PRESENT_TIMESTAMP:-0}" = 1 ] && value=1 || value=0
          ;;
        service.sf.prime_shader_cache)
          [ "${MOCK_BAD_SHADER_PRIMING:-0}" = 1 ] && value=true || value=false
          ;;
        service.adb.tcp.port) value=5555 ;;
        media.c2.hal.selection) [ "$MOCK_SDK" = 35 ] && value=aidl || value= ;;
        debug.stagefright.c2inputsurface)
          if [ "${MOCK_BAD_INPUT_SURFACE:-0}" = 1 ]; then
            value=
          elif [ "$MOCK_SDK" = 35 ]; then
            value=-1
          else
            value=
          fi
          ;;
        debug.stagefright.c2-poolmask)
          if [ "${MOCK_BAD_POOL_MASK:-0}" = 1 ]; then
            value=327680
          elif [ "$MOCK_SDK" = 35 ]; then
            value=786432
          else
            value=
          fi
          ;;
        vendor.royd.graphics.mode) value=software ;;
        ro.vendor.royd.graphics_backend) value=software ;;
        ro.vendor.royd.hal_profile) value=graphical ;;
        ro.vendor.royd.display_mode) value=interactive ;;
        vendor.royd.graphics.allocator)
          if [ "${MOCK_BAD_ALLOCATOR:-0}" = 1 ]; then
            value=wrong
          elif [ "$MOCK_SDK" = 35 ]; then
            value=aidl2-stablec5-memfd
          else
            value=gralloc0-memfd
          fi
          ;;
        ro.vendor.royd.graphics_allocator)
          [ "$MOCK_SDK" = 35 ] && value=aidl2-stablec5-memfd || value=gralloc0-memfd
          ;;
        ro.vendor.royd.graphics_mapper|vendor.royd.graphics.mapper)
          [ "$MOCK_SDK" = 35 ] && value=stablec5-royd || value=
          ;;
        ro.vendor.royd.graphics_composer|vendor.royd.graphics.composer)
          [ "$MOCK_SDK" = 35 ] && value=aidl4-client || value=
          ;;
        ro.hardware.gralloc)
          [ "$MOCK_SDK" = 35 ] && value= || value=royd
          ;;
        ro.hardware.egl)
          [ "$MOCK_SDK" = 35 ] && value= || value=swiftshader
          ;;
        ro.hardware.vulkan)
          [ "$MOCK_SDK" = 35 ] && value=pastel || value=
          ;;
        ro.hardware.hwcomposer)
          [ "$MOCK_SDK" = 35 ] && value= || value=default
          ;;
        vendor.royd.host.memfd) value=available ;;
        vendor.royd.display.ready) value=1 ;;
        vendor.royd.boot_watchdog) value=complete ;;
        vendor.royd.display.width) value=540 ;;
        vendor.royd.display.height) value=960 ;;
        vendor.royd.display.dpi) value=240 ;;
        vendor.royd.display.fps) value=30 ;;
        *) printf 'unexpected property: %s\n' "$property" >&2; exit 1 ;;
      esac
      printf '%s\n' "$value"
      exit 0
    fi
    if [ "$1" = dumpsys ] && \
        [ "$2" = android.hardware.media.c2.IComponentStore/software ]; then
      printf '%s\n' '    name: c2.android.avc.encoder'
      [ "${MOCK_BAD_CODECS:-0}" = 1 ] || printf '%s\n' '    name: c2.android.opus.encoder'
      exit 0
    fi
    if [ "$1" = dumpsys ] && [ "$2" = stats ] && [ "$3" = --metadata ]; then
      case "${MOCK_STATSD_DUMP:-good}" in
        good) printf '%s\n' 'Stats collection start second: 2026-10-15' ;;
        failed) printf '%s\n' 'FAILED_TRANSACTION'; exit 1 ;;
        invalid) printf '%s\n' "Error with service 'stats' while dumping: FAILED_TRANSACTION" ;;
      esac
      exit 0
    fi
    if [ "$1" = dumpsys ] && [ "$2" = suspend_control_internal ]; then
      case "${MOCK_SUSPEND_DUMP:-good}" in
        good) printf '%s\n' '| PowerManagerService.Booting | 455 | Native | Inactive | 0 |' ;;
        failed) exit 1 ;;
        invalid) printf '%s\n' 'Error: FAILED_TRANSACTION' ;;
      esac
      exit 0
    fi
    if [ "$1" = service ] && [ "$2" = check ]; then
      case "$3" in
        appwidget)
          [ "${MOCK_BAD_APPWIDGET:-0}" = 1 ] && \
            printf '%s\n' 'Service appwidget: not found' || \
            printf '%s\n' 'Service appwidget: found'
          ;;
        dropbox)
          [ "${MOCK_BAD_DROPBOX:-0}" = 1 ] && \
            printf '%s\n' 'Service dropbox: not found' || \
            printf '%s\n' 'Service dropbox: found'
          ;;
        jobscheduler|uimode|activity|sensor_privacy|media.audio_flinger|media.audio_policy|stats|\
        suspend_control|suspend_control_internal|android.system.suspend.ISystemSuspend/default)
          [ "${MOCK_BAD_REQUIRED_SERVICE:-}" = "$3" ] && \
            printf 'Service %s: not found\n' "$3" || \
            printf 'Service %s: found\n' "$3"
          ;;
        *) printf 'unexpected service: %s\n' "$3" >&2; exit 1 ;;
      esac
      exit 0
    fi
    if [ "$1" = pm ] && [ "$2" = list ] && [ "$3" = features ]; then
      [ "${MOCK_BAD_APPWIDGET_FEATURE:-0}" = 1 ] || \
        printf '%s\n' 'feature:android.software.app_widgets'
      exit 0
    fi
    if [ "$1" = sh ] && [ "$2" = -c ]; then
      case "$3" in
        *royd-runtime-cgroup-test*)
          [ "${MOCK_BAD_CGROUP:-0}" != 1 ] || exit 1
          ;;
        *royd-runtime-host-power-test*)
          [ "${MOCK_BAD_HOST_POWER_FD:-0}" != 1 ] || exit 1
          ;;
        *royd-runtime-launcher-test*)
          [ "${MOCK_BAD_LAUNCHER:-0}" != 1 ] || exit 1
          ;;
        *royd-runtime-memcg-path-test*)
          [ "${MOCK_BAD_MEMCG_PATH:-0}" != 1 ] || exit 1
          ;;
        *royd-runtime-legacy-cgroup-availability-test*)
          [ "${MOCK_ALL_LEGACY_CGROUPS_MOUNTED:-0}" != 1 ]
          ;;
        *royd-runtime-package-list-test*)
          [ "${MOCK_BAD_PACKAGE_LIST:-0}" != 1 ] || exit 1
          ;;
        *royd-runtime-emulated-storage-test*)
          [ "${MOCK_BAD_EMULATED_STORAGE:-0}" != 1 ] || exit 1
          ;;
        *royd-runtime-webview-cgroup-test*)
          [ "${MOCK_BAD_WEBVIEW_CGROUP:-0}" != 1 ] || exit 1
          ;;
        *royd-runtime-recents-persistence-test*)
          [ "${MOCK_BAD_RECENTS_PERSISTENCE:-0}" != 1 ] || exit 1
          if [ "${MOCK_RECENTS_DIRECTORIES_PRESENT:-0}" = 1 ]; then
            printf '%s\n' present
          else
            printf '%s\n' uncreated
          fi
          ;;
        *royd-runtime-video-test*)
          [ "${MOCK_BAD_CAPTURE:-0}" != 1 ] || exit 1
          ;;
      esac
      exit 0
    fi
    printf 'unexpected docker exec command for %s: %s\n' "$container" "$*" >&2
    exit 1
    ;;
  logs)
    if [ "$MOCK_SDK" = 35 ] && [ "${MOCK_MISSING_INIT_LOGGING_MODE:-0}" != 1 ]; then
      printf '%s\n' 'init: ROYD: routing init diagnostics to container stderr'
    fi
    if [ "$MOCK_SDK" = 35 ]; then
      [ "${MOCK_MISSING_FRAMEWORK_MARKER:-}" = begin ] || \
        printf '%s\n' 'SystemServer: ROYD: starting framework service initialisation'
      [ "${MOCK_MISSING_FRAMEWORK_MARKER:-}" = ready ] || \
        printf '%s\n' 'SystemServiceManager: ROYD: framework services initialised'
    fi
    if [ "$MOCK_SDK" = 35 ] && [ "${MOCK_MISSING_WAKELOCK_MODE:-0}" != 1 ]; then
      printf '%s\n' 'android.system.suspend-service: ROYD: keeping native wake locks in-process without host kernel wake locks'
    fi
    if [ "${MOCK_HOST_POWER_WRITE:-0}" = 1 ]; then
      printf '%s\n' 'android.system.suspend-service: error writing zygote_kwl to /sys/power/wake_unlock: Invalid argument'
    fi
    if [ "$MOCK_SDK" = 35 ] && [ "${MOCK_MISSING_RECENTS_MARKER:-0}" != 1 ]; then
      printf '%s\n' 'TaskPersister: ROYD: no obsolete files in uncreated recents directories'
    fi
    if [ "${MOCK_RECENTS_DIRECTORY_ERROR:-0}" = 1 ]; then
      printf '%s\n' "TaskPersister: File error accessing recents directory (directory doesn't exist?)."
    fi
    if [ "$MOCK_SDK" = 35 ]; then
      [ "${MOCK_MISSING_MEMEVENT_MODE:-}" = oom ] || \
        printf '%s\n' 'OomConnection: ROYD: not starting host-global OOM event listener'
      [ "${MOCK_MISSING_MEMEVENT_MODE:-}" = lmkd ] || \
        printf '%s\n' 'lowmemorykiller: ROYD: using vmstat fallback without host-global memory-event tracing'
      [ "${MOCK_MISSING_MEMEVENT_MODE:-}" = vmstat ] || \
        printf '%s\n' 'lowmemorykiller: Using vmstats for direct reclaim and kswapd detection'
    fi
    case "${MOCK_MEMEVENT_FAILURE:-}" in
      oom)
        printf '%s\n' 'system_server: memevent failed to attach bpf program to oom/mark_victim tracepoint: Permission denied'
        ;;
      reclaim)
        printf '%s\n' 'lmkd: memevent failed to attach bpf program to vmscan/mm_vmscan_direct_reclaim_begin tracepoint: Permission denied'
        ;;
    esac
    if [ "$MOCK_SDK" = 35 ] && [ "${MOCK_MISSING_STATSD_MARKER:-0}" != 1 ]; then
      printf '%s\n' 'statsd: ROYD: suppressing statsd Binder caller SID request because ROYD_CONTAINER=1 and kernel SELinux is disabled'
    fi
    if [ "${MOCK_STATSD_REGISTRATION_FAILURE:-0}" = 1 ]; then
      printf '%s\n' 'StatsManagerService: Failed to access statsd to register puller for atom 10000'
    fi
    if [ "${MOCK_EARLY_DROPBOX_RECURSION:-0}" = 1 ]; then
      printf '%s\n' 'SystemServiceRegistry: No service published for: dropbox'
    fi
    if [ "${MOCK_TETHER_STATS_FAILURE:-0}" = 1 ]; then
      printf '%s\n' 'NetworkStats: [Operation not permitted] : failed to fetch tether stats (0): -1'
    fi
    if [ "${MOCK_INET_DIAG_FAILURE:-0}" = 1 ]; then
      printf '%s\n' 'NetlinkUtils: Received unexpected netlink message: NetlinkErrorMessage'
      printf '%s\n' 'InetDiagMessage: Failed to send netlink dump request or receive messages: read failed: EAGAIN'
    fi
    if [ "${MOCK_SERVICE_REGISTRY_WTF:-0}" = 1 ]; then
      printf '%s\n' 'am_wtf: [0,1000,system_server,-1,SystemServiceRegistry,No service published for: jobscheduler]'
      printf '%s\n' 'am_wtf: [0,1073,com.android.networkstack.process,-1,SystemServiceRegistry,No service published for: ethernet]'
    fi
    if [ "${MOCK_SERVICE_MANAGER_BLOCKING_WTF:-0}" = 1 ]; then
      printf '%s\n' 'Binder: Outgoing transactions from this process must be FLAG_ONEWAY'
      printf '%s\n' 'Binder: at android.os.IServiceManager$Stub$Proxy.checkService(IServiceManager.java:507)'
    fi
    if [ "${MOCK_OTHER_BLOCKING_WTF:-0}" = 1 ]; then
      printf '%s\n' 'Binder: Outgoing transactions from this process must be FLAG_ONEWAY'
      printf '%s\n' 'Binder: at android.content.ContentProviderProxy.openTypedAssetFile(ContentProviderNative.java:812)'
    fi
    if [ "${MOCK_ART_OVERLAY_FAILURE:-0}" = 1 ]; then
      printf '%s\n' "ArtService: android.os.ServiceSpecificException: Fstab entries not found for '/system/priv-app/Settings/Settings.apk' (code 1)"
    fi
    if [ "${MOCK_METADATA_FSVERITY_FAILURE:-0}" = 1 ]; then
      printf '%s\n' 'ResilientAtomicFile: Failed to verity-protect package manager settings'
      printf '%s\n' 'ResilientAtomicFile: java.io.IOException: Failed to enable fs-verity on FD(404): Operation not supported on transport endpoint'
    fi
    if [ "${MOCK_LEGACY_CGROUP_PROFILE_FAILURE:-0}" = 1 ]; then
      printf '%s\n' 'libprocessgroup: SetCgroup::ExecuteForProcess: failed to open /dev/cpuctl/top-app/cgroup.procs: No such file or directory'
    fi
    if [ "$MOCK_SDK" = 35 ] && [ "${MOCK_MISSING_LEGACY_CGROUP_MARKER:-0}" != 1 ]; then
      printf '%s\n' 'libprocessgroup: ROYD: skipping task-profile actions for unavailable legacy cgroup controllers'
    fi
    if [ "${MOCK_OPTIONAL_SERVICE_WARNING:-0}" = 1 ]; then
      printf '%s\n' 'W SystemServiceRegistry: No service published for: usb'
    fi
    if [ "${MOCK_PACKAGE_LIST_SELINUX_WTF:-0}" = 1 ]; then
      printf '%s\n' 'am_wtf: [0,505,system_server,-1,PackageSettings,Failed to get SELinux context for /data/system/packages.list]'
      printf '%s\n' 'am_wtf: [0,505,system_server,-1,PackageSettings,Failed to set packages.list SELinux context]'
    fi
    if [ "${MOCK_CPU_MONITOR_WTF:-0}" = 1 ]; then
      printf '%s\n' 'am_wtf: [0,591,system_server,-1,CpuMonitorService,Failed to initialize CPU info reader]'
    fi
    if [ "$MOCK_SDK" = 35 ] && [ "${MOCK_MISSING_PSI_MODE:-0}" != 1 ]; then
      printf '%s\n' 'LowMemDetector: ROYD: using unprivileged 2-second PSI windows for ActivityManager'
    fi
    if [ "${MOCK_BAD_PSI_MONITOR:-0}" = 1 ]; then
      printf '%s\n' 'libpsi: psi.cpp:115 pressure/memory write failed: Invalid argument'
      printf '%s\n' 'LowMemDetector: Failed to register psi trigger'
    fi
    if [ "${MOCK_STORAGE_MOUNT_WTF:-0}" = 1 ]; then
      printf '%s\n' 'vold: emulated;0 failed to create mount points: Read-only file system'
      printf '%s\n' 'am_wtf: [0,645,system_server,-1,StorageManagerService,]'
    fi
    if [ "${MOCK_AUDIO_ACTIVITY_WAIT:-0}" = 1 ]; then
      printf '%s\n' "10-15 12:16:03.184 ${MOCK_WAIT_PID:-237} 309 W ServiceManagerCppClient: Waited one second for activity (is service started?)"
    fi
    if [ "${MOCK_AUDIO_SENSOR_PRIVACY_WAIT:-0}" = 1 ]; then
      printf '%s\n' "10-15 12:16:03.184 ${MOCK_WAIT_PID:-237} 309 W ServiceManagerCppClient: Waited one second for sensor_privacy (is service started?)"
    fi
    if [ "${MOCK_HISTORIC_AUDIO_PID:-0}" = 1 ]; then
      # Native tag evidence may appear after the shared-tag message in the retained log.
      printf '%s\n' '10-15 12:16:04.000 111 222 D audioserver: ordinary diagnostic'
    fi
    if [ "${MOCK_SYSTEM_SERVER_PRE_WATCHDOG:-0}" = 1 ]; then
      printf '%s\n' 'Watchdog: WAITED_UNTIL_PRE_WATCHDOG'
    fi
    if [ "${MOCK_DUPLICATE_CGROUP_ROOT:-0}" = 1 ]; then
      printf '%s\n' 'lowmemorykiller: Error opening /sys/fs/cgroup/royd/royd/uid_1000/pid_42/memory.low'
    fi
    if [ "${MOCK_INVALID_PRESENT_FENCE:-0}" = 1 ]; then
      printf '%s\n' 'Scheduler: trackPendingFrame: Invalid present fence'
    fi
    if [ "$MOCK_SDK" = 35 ]; then
      printf '%s\n' '[royd] graphics: allocator aidl2-stablec5-memfd and mapper stablec5-royd ready'
    else
      printf '%s\n' '[royd] graphics: allocator gralloc0-memfd ready'
    fi
    cat <<'LOGS'
[royd] graphics: software renderer selected
[royd] display: early configuration
[royd] boot-watchdog: armed timeout=120s
[royd] boot-watchdog: boot completed after 30s
[royd] binderfs: ready
LOGS
    ;;
  *)
    printf 'unexpected docker command: %s\n' "$*" >&2
    exit 1
    ;;
esac
MOCK
chmod +x "$tmp/docker"

PATH="$tmp:$PATH" MOCK_SDK=35 "$script_dir/assert-runtime.sh" android15 >/dev/null
PATH="$tmp:$PATH" MOCK_SDK=34 "$script_dir/assert-runtime.sh" android14 >/dev/null
PATH="$tmp:$PATH" MOCK_SDK=35 MOCK_OPTIONAL_SERVICE_WARNING=1 \
  "$script_dir/assert-runtime.sh" optional-service-warning >/dev/null
PATH="$tmp:$PATH" MOCK_SDK=35 MOCK_RECENTS_DIRECTORIES_PRESENT=1 MOCK_MISSING_RECENTS_MARKER=1 \
  "$script_dir/assert-runtime.sh" existing-recents-directories >/dev/null

if PATH="$tmp:$PATH" MOCK_SDK=35 MOCK_MISSING_INIT_LOGGING_MODE=1 \
    "$script_dir/assert-runtime.sh" missing-init-logging-mode >"$tmp/error" 2>&1; then
  printf '%s\n' 'error: runtime assertion accepted unreported Android 15 init logging mode' >&2
  exit 1
fi
grep -Fq 'init stderr logging mode is not reported' "$tmp/error"

if PATH="$tmp:$PATH" MOCK_SDK=35 MOCK_BAD_FRAMEWORK_READY=1 \
    "$script_dir/assert-runtime.sh" stale-device-boot-completion >"$tmp/error" 2>&1; then
  printf '%s\n' 'error: runtime assertion accepted an unready framework with stock boot completion set' >&2
  exit 1
fi
grep -Fq 'sys.royd.framework_ready expected 1, got 0' "$tmp/error"
for transition in begin ready; do
  if PATH="$tmp:$PATH" MOCK_SDK=35 MOCK_MISSING_FRAMEWORK_MARKER="$transition" \
      "$script_dir/assert-runtime.sh" missing-framework-transition >"$tmp/error" 2>&1; then
    printf '%s\n' 'error: runtime assertion accepted an unreported framework lifecycle transition' >&2
    exit 1
  fi
  grep -Fq 'framework readiness transition is not reported' "$tmp/error"
done

if PATH="$tmp:$PATH" MOCK_SDK=35 MOCK_BAD_ALLOCATOR=1 \
    "$script_dir/assert-runtime.sh" bad-allocator >"$tmp/error" 2>&1; then
  printf '%s\n' 'error: runtime assertion accepted an incorrect Android 15 allocator' >&2
  exit 1
fi
grep -Fq 'vendor.royd.graphics.allocator expected aidl2-stablec5-memfd, got wrong' "$tmp/error"

if PATH="$tmp:$PATH" MOCK_SDK=35 MOCK_BAD_CODECS=1 \
    "$script_dir/assert-runtime.sh" bad-codecs >"$tmp/error" 2>&1; then
  printf '%s\n' 'error: runtime assertion accepted an incomplete Android 15 Codec2 store' >&2
  exit 1
fi
grep -Fq 'software Codec2 store omits c2.android.opus.encoder' "$tmp/error"

if PATH="$tmp:$PATH" MOCK_SDK=35 MOCK_BAD_INPUT_SURFACE=1 \
    "$script_dir/assert-runtime.sh" bad-input-surface >"$tmp/error" 2>&1; then
  printf '%s\n' 'error: runtime assertion accepted an unavailable Android 15 Codec2 input surface' >&2
  exit 1
fi
grep -Fq 'debug.stagefright.c2inputsurface expected -1, got <empty>' "$tmp/error"

if PATH="$tmp:$PATH" MOCK_SDK=35 MOCK_BAD_POOL_MASK=1 \
    "$script_dir/assert-runtime.sh" bad-pool-mask >"$tmp/error" 2>&1; then
  printf '%s\n' 'error: runtime assertion accepted the unavailable Android 15 dma-buf linear pool' >&2
  exit 1
fi
grep -Fq 'debug.stagefright.c2-poolmask expected 786432, got 327680' "$tmp/error"

if PATH="$tmp:$PATH" MOCK_SDK=35 MOCK_BAD_CAPTURE=1 \
    "$script_dir/assert-runtime.sh" bad-capture >"$tmp/error" 2>&1; then
  printf '%s\n' 'error: runtime assertion accepted an empty Android 15 display capture' >&2
  exit 1
fi
grep -Fq 'Android 15 graphical capture produced no H.264 frames' "$tmp/error"

if PATH="$tmp:$PATH" MOCK_SDK=35 MOCK_INVALID_PRESENT_FENCE=1 \
    "$script_dir/assert-runtime.sh" invalid-present-fence >"$tmp/error" 2>&1; then
  printf '%s\n' 'error: runtime assertion accepted an invalid Android 15 present fence' >&2
  exit 1
fi
grep -Fq 'Android 15 SurfaceFlinger received an invalid present fence' "$tmp/error"

if PATH="$tmp:$PATH" MOCK_SDK=35 MOCK_BAD_PRESENT_TIMESTAMP=1 \
    "$script_dir/assert-runtime.sh" reliable-present-timestamp >"$tmp/error" 2>&1; then
  printf '%s\n' 'error: runtime assertion accepted Android 15 present-fence tracking' >&2
  exit 1
fi
grep -Fq 'service.sf.present_timestamp expected 0, got 1' "$tmp/error"

if PATH="$tmp:$PATH" MOCK_SDK=35 MOCK_BAD_SHADER_PRIMING=1 \
    "$script_dir/assert-runtime.sh" eager-shader-priming >"$tmp/error" 2>&1; then
  printf '%s\n' 'error: runtime assertion accepted eager Android 15 software shader priming' >&2
  exit 1
fi
grep -Fq 'service.sf.prime_shader_cache expected false, got true' "$tmp/error"

if PATH="$tmp:$PATH" MOCK_SDK=35 MOCK_BAD_DROPBOX=1 \
    "$script_dir/assert-runtime.sh" bad-dropbox >"$tmp/error" 2>&1; then
  printf '%s\n' 'error: runtime assertion accepted a missing Android 15 DropBox service' >&2
  exit 1
fi
grep -Fq 'Android 15 DropBox service is unavailable' "$tmp/error"

if PATH="$tmp:$PATH" MOCK_SDK=35 MOCK_EARLY_DROPBOX_RECURSION=1 \
    "$script_dir/assert-runtime.sh" recursive-dropbox >"$tmp/error" 2>&1; then
  printf '%s\n' 'error: runtime assertion accepted recursive Android 15 DropBox reporting' >&2
  exit 1
fi
grep -Fq 'Android 15 recursively reported the unpublished DropBox service' "$tmp/error"

if PATH="$tmp:$PATH" MOCK_SDK=35 MOCK_TETHER_STATS_FAILURE=1 \
    "$script_dir/assert-runtime.sh" tether-stats >"$tmp/error" 2>&1; then
  printf '%s\n' 'error: runtime assertion accepted repeated Android 15 tether-stat failures' >&2
  exit 1
fi
grep -Fq 'Android 15 repeatedly queried unavailable idle tether counters' "$tmp/error"

if PATH="$tmp:$PATH" MOCK_SDK=35 MOCK_INET_DIAG_FAILURE=1 \
    "$script_dir/assert-runtime.sh" inet-diag >"$tmp/error" 2>&1; then
  printf '%s\n' 'error: runtime assertion accepted repeated Android 15 inet-diag timeouts' >&2
  exit 1
fi
grep -Fq 'Android 15 repeated unavailable inet-diag socket dumps' "$tmp/error"

if PATH="$tmp:$PATH" MOCK_SDK=35 MOCK_SERVICE_REGISTRY_WTF=1 \
    "$script_dir/assert-runtime.sh" service-registry-wtf >"$tmp/error" 2>&1; then
  printf '%s\n' 'error: runtime assertion accepted Android 15 service-registry WTFs' >&2
  exit 1
fi
grep -Fq 'Android 15 emitted missing-service WTF diagnostics' "$tmp/error"

if PATH="$tmp:$PATH" MOCK_SDK=35 MOCK_SERVICE_MANAGER_BLOCKING_WTF=1 \
    "$script_dir/assert-runtime.sh" service-manager-blocking >"$tmp/error" 2>&1; then
  printf '%s\n' 'error: runtime assertion accepted an Android 15 ServiceManager blocking WTF' >&2
  exit 1
fi
grep -Fq 'Android 15 native ServiceManager proxy triggered a blocking-call WTF' "$tmp/error"

PATH="$tmp:$PATH" MOCK_SDK=35 MOCK_OTHER_BLOCKING_WTF=1 \
  "$script_dir/assert-runtime.sh" unrelated-blocking-wtf >/dev/null

PATH="$tmp:$PATH" MOCK_SDK=35 ROYD_RESOURCE_PROFILE=performance \
  "$script_dir/assert-runtime.sh" performance-resource-profile >/dev/null

if PATH="$tmp:$PATH" MOCK_SDK=35 ROYD_RESOURCE_PROFILE=performance \
    MOCK_BAD_PER_APP_MEMCG=1 \
    "$script_dir/assert-runtime.sh" disabled-performance-memcg >"$tmp/error" 2>&1; then
  printf '%s\n' 'error: runtime assertion accepted disabled performance per-app memcg' >&2
  exit 1
fi
grep -Fq 'ro.config.per_app_memcg expected true, got false' "$tmp/error"

if PATH="$tmp:$PATH" MOCK_SDK=35 ROYD_RESOURCE_PROFILE=performance \
    MOCK_BAD_RESOURCE_PROFILE=1 \
    "$script_dir/assert-runtime.sh" mismatched-resource-profile >"$tmp/error" 2>&1; then
  printf '%s\n' 'error: runtime assertion accepted a mismatched resource profile' >&2
  exit 1
fi
grep -Fq 'ro.vendor.royd.resource_profile expected performance, got low-memory' "$tmp/error"

if PATH="$tmp:$PATH" MOCK_SDK=35 MOCK_BAD_PACKAGE_LIST=1 \
    "$script_dir/assert-runtime.sh" missing-package-list >"$tmp/error" 2>&1; then
  printf '%s\n' 'error: runtime assertion accepted a missing Android 15 packages.list' >&2
  exit 1
fi
grep -Fq 'Android 15 packages.list is missing or empty' "$tmp/error"

if PATH="$tmp:$PATH" MOCK_SDK=35 MOCK_PACKAGE_LIST_SELINUX_WTF=1 \
    "$script_dir/assert-runtime.sh" package-list-selinux >"$tmp/error" 2>&1; then
  printf '%s\n' 'error: runtime assertion accepted Android 15 packages.list SELinux WTFs' >&2
  exit 1
fi
grep -Fq 'Android 15 attempted unavailable packages.list SELinux context setup' "$tmp/error"

if PATH="$tmp:$PATH" MOCK_SDK=35 MOCK_CPU_MONITOR_WTF=1 \
    "$script_dir/assert-runtime.sh" cpu-monitor >"$tmp/error" 2>&1; then
  printf '%s\n' 'error: runtime assertion accepted an unavailable Android 15 CPU monitor' >&2
  exit 1
fi
grep -Fq 'Android 15 started its unavailable CPU frequency monitor' "$tmp/error"

if PATH="$tmp:$PATH" MOCK_SDK=35 MOCK_MISSING_PSI_MODE=1 \
    "$script_dir/assert-runtime.sh" missing-psi-mode >"$tmp/error" 2>&1; then
  printf '%s\n' 'error: runtime assertion accepted an unconfigured Android 15 PSI monitor' >&2
  exit 1
fi
grep -Fq 'Android 15 did not enable its unprivileged ActivityManager PSI monitor' "$tmp/error"

if PATH="$tmp:$PATH" MOCK_SDK=35 MOCK_BAD_PSI_MONITOR=1 \
    "$script_dir/assert-runtime.sh" failed-psi-monitor >"$tmp/error" 2>&1; then
  printf '%s\n' 'error: runtime assertion accepted a failed Android 15 PSI monitor' >&2
  exit 1
fi
grep -Fq 'Android 15 ActivityManager PSI monitor failed to register' "$tmp/error"

if PATH="$tmp:$PATH" MOCK_SDK=35 MOCK_BAD_EMULATED_STORAGE=1 \
    "$script_dir/assert-runtime.sh" missing-emulated-storage >"$tmp/error" 2>&1; then
  printf '%s\n' 'error: runtime assertion accepted unavailable Android 15 emulated storage' >&2
  exit 1
fi
grep -Fq 'Android 15 emulated storage is not mounted' "$tmp/error"

if PATH="$tmp:$PATH" MOCK_SDK=35 MOCK_STORAGE_MOUNT_WTF=1 \
    "$script_dir/assert-runtime.sh" emulated-storage-wtf >"$tmp/error" 2>&1; then
  printf '%s\n' 'error: runtime assertion accepted an Android 15 emulated-storage mount failure' >&2
  exit 1
fi
grep -Fq 'Android 15 emulated storage mount failed' "$tmp/error"

if PATH="$tmp:$PATH" MOCK_SDK=35 MOCK_AUDIO_ACTIVITY_WAIT=1 \
    "$script_dir/assert-runtime.sh" audio-activity-wait >"$tmp/error" 2>&1; then
  printf '%s\n' 'error: runtime assertion accepted a blocking Android 15 ActivityManager lookup' >&2
  exit 1
fi
grep -Fq 'Android 15 blocked audioserver on unpublished ActivityManager' "$tmp/error"

if PATH="$tmp:$PATH" MOCK_SDK=35 MOCK_AUDIO_SENSOR_PRIVACY_WAIT=1 \
    "$script_dir/assert-runtime.sh" audio-sensor-privacy-wait >"$tmp/error" 2>&1; then
  printf '%s\n' 'error: runtime assertion accepted a blocking Android 15 sensor-privacy lookup' >&2
  exit 1
fi
grep -Fq 'Android 15 blocked audioserver on unpublished sensor privacy' "$tmp/error"

# Other services may legitimately wait while a framework is being replaced. Keep their
# diagnostics visible without misclassifying them as an audioserver startup dependency.
PATH="$tmp:$PATH" MOCK_SDK=35 MOCK_AUDIO_ACTIVITY_WAIT=1 MOCK_AUDIO_SENSOR_PRIVACY_WAIT=1 \
  MOCK_WAIT_PID=309 "$script_dir/assert-runtime.sh" cameraserver-wait >/dev/null
for service in ACTIVITY SENSOR_PRIVACY; do
  if env PATH="$tmp:$PATH" MOCK_SDK=35 "MOCK_AUDIO_${service}_WAIT=1" \
      MOCK_WAIT_PID=111 MOCK_HISTORIC_AUDIO_PID=1 \
      "$script_dir/assert-runtime.sh" former-audioserver-wait >"$tmp/error" 2>&1; then
    printf '%s\n' 'error: runtime assertion accepted a former audioserver blocking lookup' >&2
    exit 1
  fi
  grep -Fq 'Android 15 blocked audioserver on unpublished' "$tmp/error"
done
for pid in '' 0 '237 238' invalid; do
  if PATH="$tmp:$PATH" MOCK_SDK=35 MOCK_AUDIO_PID="$pid" \
      "$script_dir/assert-runtime.sh" missing-audio-pid >"$tmp/error" 2>&1; then
    printf '%s\n' 'error: runtime assertion accepted an unavailable audioserver PID' >&2
    exit 1
  fi
  grep -Fq 'audioserver PID is unavailable' "$tmp/error"
done

if PATH="$tmp:$PATH" MOCK_SDK=35 MOCK_SYSTEM_SERVER_PRE_WATCHDOG=1 \
    "$script_dir/assert-runtime.sh" pre-watchdog >"$tmp/error" 2>&1; then
  printf '%s\n' 'error: runtime assertion accepted an Android 15 SystemServer pre-watchdog' >&2
  exit 1
fi
grep -Fq 'Android 15 triggered a SystemServer pre-watchdog' "$tmp/error"

if PATH="$tmp:$PATH" MOCK_SDK=35 MOCK_BAD_REQUIRED_SERVICE=media.audio_policy \
    "$script_dir/assert-runtime.sh" missing-audio-policy >"$tmp/error" 2>&1; then
  printf '%s\n' 'error: runtime assertion accepted a missing Android 15 audio policy service' >&2
  exit 1
fi
grep -Fq 'Android 15 required service media.audio_policy is unavailable' "$tmp/error"

if PATH="$tmp:$PATH" MOCK_SDK=35 MOCK_BAD_REQUIRED_SERVICE=sensor_privacy \
    "$script_dir/assert-runtime.sh" missing-sensor-privacy >"$tmp/error" 2>&1; then
  printf '%s\n' 'error: runtime assertion accepted a missing Android 15 sensor-privacy service' >&2
  exit 1
fi
grep -Fq 'Android 15 required service sensor_privacy is unavailable' "$tmp/error"

if PATH="$tmp:$PATH" MOCK_SDK=35 MOCK_BAD_REQUIRED_SERVICE=jobscheduler \
    "$script_dir/assert-runtime.sh" missing-jobscheduler >"$tmp/error" 2>&1; then
  printf '%s\n' 'error: runtime assertion accepted a missing Android 15 JobScheduler service' >&2
  exit 1
fi
grep -Fq 'Android 15 required service jobscheduler is unavailable' "$tmp/error"

if PATH="$tmp:$PATH" MOCK_SDK=35 MOCK_BAD_REQUIRED_SERVICE=stats \
    "$script_dir/assert-runtime.sh" missing-stats >"$tmp/error" 2>&1; then
  printf '%s\n' 'error: runtime assertion accepted an absent statsd Binder service' >&2
  exit 1
fi
grep -Fq 'Android 15 required service stats is unavailable' "$tmp/error"
for service in suspend_control suspend_control_internal android.system.suspend.ISystemSuspend/default; do
  if PATH="$tmp:$PATH" MOCK_SDK=35 MOCK_BAD_REQUIRED_SERVICE="$service" \
      "$script_dir/assert-runtime.sh" missing-suspend-service >"$tmp/error" 2>&1; then
    printf '%s\n' 'error: runtime assertion accepted an absent suspend service' >&2
    exit 1
  fi
  grep -Fq "Android 15 required service $service is unavailable" "$tmp/error"
done
if PATH="$tmp:$PATH" MOCK_SDK=35 MOCK_MISSING_WAKELOCK_MODE=1 \
    "$script_dir/assert-runtime.sh" missing-wakelock-mode >"$tmp/error" 2>&1; then
  printf '%s\n' 'error: runtime assertion accepted unreported native wake-lock mode' >&2
  exit 1
fi
grep -Fq 'in-process wake-lock mode is not reported' "$tmp/error"
for response in failed invalid; do
  if PATH="$tmp:$PATH" MOCK_SDK=35 MOCK_SUSPEND_DUMP="$response" \
      "$script_dir/assert-runtime.sh" missing-native-wakelocks >"$tmp/error" 2>&1; then
    printf '%s\n' 'error: runtime assertion accepted unavailable native wake-lock statistics' >&2
    exit 1
  fi
  grep -Eq 'native wake-lock statistics (dump failed|are unavailable)' "$tmp/error"
done
if PATH="$tmp:$PATH" MOCK_SDK=35 MOCK_BAD_HOST_POWER_FD=1 \
    "$script_dir/assert-runtime.sh" host-power-fd >"$tmp/error" 2>&1; then
  printf '%s\n' 'error: runtime assertion accepted a SystemSuspend host-power descriptor' >&2
  exit 1
fi
grep -Fq 'SystemSuspend host-power descriptor isolation failed' "$tmp/error"
if PATH="$tmp:$PATH" MOCK_SDK=35 MOCK_HOST_POWER_WRITE=1 \
    "$script_dir/assert-runtime.sh" host-power-write >"$tmp/error" 2>&1; then
  printf '%s\n' 'error: runtime assertion accepted a SystemSuspend host-power write' >&2
  exit 1
fi
grep -Fq 'SystemSuspend attempted host power control' "$tmp/error"
for failure in failed invalid; do
  if PATH="$tmp:$PATH" MOCK_SDK=35 MOCK_STATSD_DUMP="$failure" \
      "$script_dir/assert-runtime.sh" broken-stats >"$tmp/error" 2>&1; then
    printf '%s\n' 'error: runtime assertion accepted a broken statsd Binder response' >&2
    exit 1
  fi
  grep -Eq 'statsd Binder metadata (dump failed|response is invalid)' "$tmp/error"
done
if PATH="$tmp:$PATH" MOCK_SDK=35 MOCK_MISSING_STATSD_MARKER=1 \
    "$script_dir/assert-runtime.sh" missing-stats-marker >"$tmp/error" 2>&1; then
  printf '%s\n' 'error: runtime assertion accepted an absent statsd SID marker' >&2
  exit 1
fi
grep -Fq 'statsd container Binder SID mode is not reported' "$tmp/error"
if PATH="$tmp:$PATH" MOCK_SDK=35 MOCK_STATSD_REGISTRATION_FAILURE=1 \
    "$script_dir/assert-runtime.sh" broken-stats-registration >"$tmp/error" 2>&1; then
  printf '%s\n' 'error: runtime assertion accepted a statsd puller registration failure' >&2
  exit 1
fi
grep -Fq 'statsd Binder registration failed' "$tmp/error"

if PATH="$tmp:$PATH" MOCK_SDK=35 MOCK_BAD_LMKD=1 \
    "$script_dir/assert-runtime.sh" broken-lmkd >"$tmp/error" 2>&1; then
  printf '%s\n' 'error: runtime assertion accepted a restarting lmkd' >&2
  exit 1
fi
grep -Fq 'init.svc.lmkd expected running' "$tmp/error"
for mode in oom lmkd vmstat; do
  if PATH="$tmp:$PATH" MOCK_SDK=35 MOCK_MISSING_MEMEVENT_MODE="$mode" \
      "$script_dir/assert-runtime.sh" missing-memory-event-mode >"$tmp/error" 2>&1; then
    printf '%s\n' 'error: runtime assertion accepted an unreported memory-event fallback' >&2
    exit 1
  fi
  grep -Fq 'memory-event container fallback is not reported' "$tmp/error"
done
for event in oom reclaim; do
  if PATH="$tmp:$PATH" MOCK_SDK=35 MOCK_MEMEVENT_FAILURE="$event" \
      "$script_dir/assert-runtime.sh" host-global-memory-events >"$tmp/error" 2>&1; then
    printf '%s\n' 'error: runtime assertion accepted host-global memory-event tracing' >&2
    exit 1
  fi
  grep -Fq 'attempted host-global memory-event tracing' "$tmp/error"
done

if PATH="$tmp:$PATH" MOCK_SDK=35 MOCK_BAD_APPWIDGET=1 \
    "$script_dir/assert-runtime.sh" bad-appwidget >"$tmp/error" 2>&1; then
  printf '%s\n' 'error: runtime assertion accepted a missing Android 15 AppWidget service' >&2
  exit 1
fi
grep -Fq 'Android 15 AppWidget service is unavailable' "$tmp/error"

if PATH="$tmp:$PATH" MOCK_SDK=35 MOCK_BAD_APPWIDGET_FEATURE=1 \
    "$script_dir/assert-runtime.sh" bad-appwidget-feature >"$tmp/error" 2>&1; then
  printf '%s\n' 'error: runtime assertion accepted a missing Android 15 app-widget feature' >&2
  exit 1
fi
grep -Fq 'Android 15 app-widget feature is not declared' "$tmp/error"

if PATH="$tmp:$PATH" MOCK_SDK=35 MOCK_BAD_LAUNCHER=1 \
    "$script_dir/assert-runtime.sh" bad-launcher >"$tmp/error" 2>&1; then
  printf '%s\n' 'error: runtime assertion accepted an unstable Android 15 Launcher3 process' >&2
  exit 1
fi
grep -Fq 'Android 15 Launcher3 did not remain stable after unlock' "$tmp/error"

if PATH="$tmp:$PATH" MOCK_SDK=35 MOCK_BAD_MEMCG_PATH=1 \
    "$script_dir/assert-runtime.sh" bad-memcg-path >"$tmp/error" 2>&1; then
  printf '%s\n' 'error: runtime assertion accepted an inactive Android 15 memory.low policy' >&2
  exit 1
fi
grep -Fq 'Android 15 per-process memory.low policy is not active' "$tmp/error"

if PATH="$tmp:$PATH" MOCK_SDK=35 MOCK_DUPLICATE_CGROUP_ROOT=1 \
    "$script_dir/assert-runtime.sh" duplicate-cgroup-root >"$tmp/error" 2>&1; then
  printf '%s\n' 'error: runtime assertion accepted a duplicated Android 15 cgroup root' >&2
  exit 1
fi
grep -Fq 'Android 15 duplicated its delegated cgroup root' "$tmp/error"

if PATH="$tmp:$PATH" MOCK_SDK=35 MOCK_ART_OVERLAY_FAILURE=1 \
    "$script_dir/assert-runtime.sh" art-overlay >"$tmp/error" 2>&1; then
  printf '%s\n' 'error: runtime assertion accepted an unclassified Android 15 system overlay' >&2
  exit 1
fi
grep -Fq 'Android 15 ART could not classify the OCI system overlay' "$tmp/error"

if PATH="$tmp:$PATH" MOCK_SDK=35 MOCK_METADATA_FSVERITY_FAILURE=1 \
    "$script_dir/assert-runtime.sh" metadata-fsverity >"$tmp/error" 2>&1; then
  printf '%s\n' 'error: runtime assertion accepted unavailable Android 15 metadata fs-verity' >&2
  exit 1
fi
grep -Fq 'Android 15 attempted unavailable metadata fs-verity protection' "$tmp/error"

if PATH="$tmp:$PATH" MOCK_SDK=35 MOCK_LEGACY_CGROUP_PROFILE_FAILURE=1 \
    "$script_dir/assert-runtime.sh" legacy-cgroup-profile >"$tmp/error" 2>&1; then
  printf '%s\n' 'error: runtime assertion accepted unavailable Android 15 legacy cgroup profiles' >&2
  exit 1
fi
grep -Fq 'Android 15 attempted unavailable legacy cgroup task profiles' "$tmp/error"

if PATH="$tmp:$PATH" MOCK_SDK=35 MOCK_MISSING_LEGACY_CGROUP_MARKER=1 \
    "$script_dir/assert-runtime.sh" missing-legacy-cgroup-marker >"$tmp/error" 2>&1; then
  printf '%s\n' 'error: runtime assertion accepted a missing legacy cgroup-profile marker' >&2
  exit 1
fi
grep -Fq 'Android 15 did not report unavailable legacy cgroup task profiles' "$tmp/error"

PATH="$tmp:$PATH" MOCK_SDK=35 MOCK_MISSING_LEGACY_CGROUP_MARKER=1 \
  MOCK_ALL_LEGACY_CGROUPS_MOUNTED=1 \
  "$script_dir/assert-runtime.sh" mounted-legacy-cgroups >/dev/null

if PATH="$tmp:$PATH" MOCK_SDK=35 MOCK_BAD_CGROUP=1 \
    "$script_dir/assert-runtime.sh" bad-cgroup >"$tmp/error" 2>&1; then
  printf '%s\n' 'error: runtime assertion accepted an unavailable Android 15 cgroup-v2 subtree' >&2
  exit 1
fi
grep -Fq 'Android 15 delegated cgroup-v2 subtree is not ready' "$tmp/error"

if PATH="$tmp:$PATH" MOCK_SDK=35 MOCK_BAD_WEBVIEW_CGROUP=1 \
    "$script_dir/assert-runtime.sh" bad-webview-cgroup >"$tmp/error" 2>&1; then
  printf '%s\n' 'error: runtime assertion accepted a WebView system_server restart' >&2
  exit 1
fi
grep -Fq 'Android 15 WebView process groups restarted system_server' "$tmp/error"

if PATH="$tmp:$PATH" MOCK_SDK=35 MOCK_BAD_RECENTS_PERSISTENCE=1 \
    "$script_dir/assert-runtime.sh" broken-recents-persistence >"$tmp/error" 2>&1; then
  printf '%s\n' 'error: runtime assertion accepted missing persisted recent tasks' >&2
  exit 1
fi
grep -Fq 'recent tasks were not persisted after the workload' "$tmp/error"
if PATH="$tmp:$PATH" MOCK_SDK=35 MOCK_MISSING_RECENTS_MARKER=1 \
    "$script_dir/assert-runtime.sh" missing-recents-marker >"$tmp/error" 2>&1; then
  printf '%s\n' 'error: runtime assertion accepted an unreported uncreated recents directory' >&2
  exit 1
fi
grep -Fq 'uncreated recents-directory mode is not reported' "$tmp/error"
if PATH="$tmp:$PATH" MOCK_SDK=35 MOCK_RECENTS_DIRECTORY_ERROR=1 \
    "$script_dir/assert-runtime.sh" recents-directory-error >"$tmp/error" 2>&1; then
  printf '%s\n' 'error: runtime assertion accepted a recents-directory access error' >&2
  exit 1
fi
grep -Fq 'recents cleanup could not list its directories' "$tmp/error"

if PATH="$tmp:$PATH" MOCK_SDK=35 MOCK_BAD_NETD=1 \
    "$script_dir/assert-runtime.sh" bad-netd >"$tmp/error" 2>&1; then
  printf '%s\n' 'error: runtime assertion accepted a restarting Android 15 netd' >&2
  exit 1
fi
grep -Fq 'init.svc.netd expected running, got restarting' "$tmp/error"

printf '%s\n' 'Runtime version-specific assertion contract test passed'
