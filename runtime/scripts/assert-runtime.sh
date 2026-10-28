#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
container=${1:-royd}
hal_profile=${ROYD_HAL_PROFILE:-graphical}
graphics_backend=${ROYD_GRAPHICS_BACKEND:-software}
case "$hal_profile" in
  graphical) display_mode=interactive ;;
  headless) display_mode=headless ;;
  *) printf 'error: unsupported HAL profile: %s\n' "$hal_profile" >&2; exit 1 ;;
esac

command -v docker >/dev/null 2>&1 || {
  printf '%s\n' 'error: docker is required for runtime validation' >&2
  exit 1
}

docker inspect "$container" >/dev/null 2>&1 || {
  printf 'error: container not found: %s\n' "$container" >&2
  exit 1
}

sdk=$(docker exec "$container" getprop ro.build.version.sdk 2>/dev/null | tr -d '\r')
case "$sdk" in
  ''|*[!0-9]*)
    printf 'error: ro.build.version.sdk is not numeric in %s: %s\n' "$container" "${sdk:-<empty>}" >&2
    exit 1
    ;;
esac

if [ "$sdk" = 35 ]; then
  "$script_dir/assert-app-responsiveness.sh" "$container"
fi

resource_profile=${ROYD_RESOURCE_PROFILE:-low-memory}
case "$resource_profile:$sdk" in
  low-memory:*)
    resource_low_ram=true
    resource_heap_start=5m
    resource_heap_growth=48m
    resource_heap_size=128m
    resource_heap_max_free=2m
    ;;
  performance:35)
    resource_low_ram=false
    resource_heap_start=8m
    resource_heap_growth=192m
    resource_heap_size=512m
    resource_heap_max_free=8m
    ;;
  performance:*)
    printf 'error: performance resource profile requires Android 15, got SDK %s\n' "$sdk" >&2
    exit 1
    ;;
  *)
    printf 'error: unsupported resource profile: %s\n' "$resource_profile" >&2
    exit 1
    ;;
esac

graphics_mapper=
graphics_composer=
vulkan_hal=
case "$graphics_backend:$sdk" in
  software:35)
    graphics_mode=software
    graphics_allocator=aidl2-stablec5-memfd
    graphics_mapper=stablec5-royd
    graphics_composer=aidl4-client
    gralloc_hal=
    egl_hal=
    vulkan_hal=pastel
    hwcomposer_hal=
    allocator_readiness="[royd] graphics: allocator $graphics_allocator and mapper $graphics_mapper ready"
    ;;
  software:*)
    graphics_mode=software
    graphics_allocator=gralloc0-memfd
    gralloc_hal=royd
    egl_hal=swiftshader
    hwcomposer_hal=default
    allocator_readiness="[royd] graphics: allocator $graphics_allocator ready"
    ;;
  host-gpu-generic:*)
    graphics_mode=host-gpu
    graphics_allocator=minigbm
    gralloc_hal=minigbm
    egl_hal=mesa
    hwcomposer_hal=default
    [ "$sdk" = 35 ] && hwcomposer_hal=
    [ "$sdk" = 35 ] && graphics_composer=aidl4-client
    allocator_readiness="[royd] graphics: allocator $graphics_allocator ready"
    ;;
  host-gpu-intel:*)
    graphics_mode=host-gpu
    graphics_allocator=minigbm-intel
    gralloc_hal=minigbm_intel
    egl_hal=mesa
    hwcomposer_hal=default
    [ "$sdk" = 35 ] && hwcomposer_hal=
    [ "$sdk" = 35 ] && graphics_composer=aidl4-client
    allocator_readiness="[royd] graphics: allocator $graphics_allocator ready"
    ;;
  *)
    printf 'error: unsupported graphics backend: %s\n' "$graphics_backend" >&2
    exit 1
    ;;
esac

assert_property() {
  name=$1
  expected=$2
  actual=$(docker exec "$container" getprop "$name" 2>/dev/null | tr -d '\r')
  if [ "$actual" != "$expected" ]; then
    printf 'error: %s expected %s, got %s in %s\n' "$name" "$expected" "${actual:-<empty>}" "$container" >&2
    exit 1
  fi
}

assert_property sys.boot_completed 1
assert_property ro.config.low_ram "$resource_low_ram"
assert_property init.svc.royd-logcat running
assert_property init.svc.adbd running
assert_property service.adb.tcp.port 5555
assert_property vendor.royd.graphics.mode "$graphics_mode"
assert_property ro.vendor.royd.graphics_backend "$graphics_backend"
assert_property ro.vendor.royd.hal_profile "$hal_profile"
assert_property ro.vendor.royd.display_mode "$display_mode"
assert_property vendor.royd.graphics.allocator "$graphics_allocator"
if [ -n "$graphics_mapper" ]; then
  assert_property ro.vendor.royd.graphics_allocator "$graphics_allocator"
  assert_property ro.vendor.royd.graphics_mapper "$graphics_mapper"
  assert_property vendor.royd.graphics.mapper "$graphics_mapper"
fi
if [ -n "$graphics_composer" ]; then
  assert_property ro.vendor.royd.graphics_composer "$graphics_composer"
  assert_property vendor.royd.graphics.composer "$graphics_composer"
fi
assert_property ro.hardware.gralloc "$gralloc_hal"
assert_property ro.hardware.egl "$egl_hal"
if [ -n "$vulkan_hal" ]; then
  assert_property ro.hardware.vulkan "$vulkan_hal"
fi
assert_property ro.hardware.hwcomposer "$hwcomposer_hal"
assert_property vendor.royd.host.memfd available
assert_property vendor.royd.display.ready 1
assert_property vendor.royd.boot_watchdog complete

if [ "$sdk" = 35 ]; then
  if ! docker logs "$container" 2>&1 | grep -Fq \
      'ROYD: routing init diagnostics to container stderr'; then
    printf 'error: Android 15 init stderr logging mode is not reported in %s\n' "$container" >&2
    exit 1
  fi
  assert_property sys.royd.framework_ready 1
  if ! docker logs "$container" 2>&1 | grep -Fq 'ROYD: host wall clock is read-only'; then
    printf 'error: Android 15 read-only host-clock policy is missing in %s\n' "$container" >&2
    exit 1
  fi
  if ! docker logs "$container" 2>&1 | grep -Fq 'ROYD: published OCI-owned eth0 network '; then
    printf 'error: Android 15 OCI network publication is missing in %s\n' "$container" >&2
    exit 1
  fi
  if docker logs "$container" 2>&1 | grep -Fq \
      'ROYD: leaving the active network stats map unchanged because the PF_KEY RCU barrier is unavailable'; then
    printf 'error: Android 15 froze UID statistics instead of completing RCU-protected rotation in %s\n' "$container" >&2
    exit 1
  fi
  if docker logs "$container" 2>&1 | grep -Eq 'synchronizeKernelRCU( probe)? failed'; then
    printf 'error: Android 15 UID statistics RCU barrier failed in %s\n' "$container" >&2
    exit 1
  fi
  connectivity=$(docker exec "$container" timeout 15 dumpsys connectivity)
  if ! docker logs "$container" 2>&1 | grep -Fq \
      'ROYD: enforcing OCI metered UID deny policy through cgroup BPF'; then
    printf 'error: Android 15 OCI metered deny backend is missing in %s\n' "$container" >&2
    exit 1
  fi
  metered_ifindex=$(docker exec "$container" cat /sys/class/net/eth0/ifindex)
  if ! docker logs "$container" 2>&1 | grep -Fq 'ROYD: enforcing OCI Data Saver through cgroup BPF'; then
    printf 'error: Android 15 OCI Data Saver backend is missing in %s\n' "$container" >&2
    exit 1
  fi
  case "$metered_ifindex" in
    ''|*[!0-9]*|0|1)
      printf 'error: Android 15 OCI metered interface index is invalid in %s\n' "$container" >&2
      exit 1 ;;
  esac
  metered_map=$(docker exec "$container" timeout 15 dumpsys connectivity trafficcontroller)
  if ! docker logs "$container" 2>&1 | grep -Fq \
      'ROYD: accounting OCI eth0 IP traffic through private BPF links'; then
    printf 'error: Android 15 interface IP accounting backend is missing in %s\n' "$container" >&2
    exit 1
  fi
  accounting=$(docker exec "$container" timeout 15 dumpsys netd)
  if ! printf '%s\n' "$accounting" | grep -Fxq \
      "royd interface accounting: ifindex=$metered_ifindex errors=0 links=ready"; then
    printf 'error: Android 15 interface IP accounting is unavailable in %s\n' "$container" >&2
    exit 1
  fi
  if ! docker logs "$container" 2>&1 | grep -Fq \
      'ROYD: enforcing OCI eth0 byte quotas through private BPF links'; then
    printf 'error: Android 15 interface quota backend is missing in %s\n' "$container" >&2
    exit 1
  fi
  if ! printf '%s\n' "$accounting" | awk -f "$script_dir/assert-interface-quota.awk"; then
    printf 'error: Android 15 interface quota state is unavailable or inconsistent in %s\n' "$container" >&2
    exit 1
  fi
  if ! printf '%s\n' "$metered_map" | grep -Eq "^[[:space:]]*sRoydMeteredIfaceMap: $metered_ifindex$"; then
    printf 'error: Android 15 OCI metered deny interface does not match eth0 in %s\n' "$container" >&2
    exit 1
  fi
  if ! printf '%s\n' "$connectivity" | grep -Eq '^Active default network: [0-9]+$'; then
    printf 'error: Android 15 has no framework default network in %s\n' "$container" >&2
    exit 1
  fi
  for framework_marker in \
      'ROYD: starting framework service initialisation' \
      'ROYD: framework services initialised'; do
    if ! docker logs "$container" 2>&1 | grep -Fq "$framework_marker"; then
      printf 'error: Android 15 framework readiness transition is not reported in %s: %s\n' \
        "$container" "$framework_marker" >&2
      exit 1
    fi
  done
  assert_property ro.vendor.royd.resource_profile "$resource_profile"
  assert_property ro.config.per_app_memcg true
  assert_property dalvik.vm.heapstartsize "$resource_heap_start"
  assert_property dalvik.vm.heapgrowthlimit "$resource_heap_growth"
  assert_property dalvik.vm.heapsize "$resource_heap_size"
  assert_property dalvik.vm.heaptargetutilization 0.75
  assert_property dalvik.vm.heapminfree 512k
  assert_property dalvik.vm.heapmaxfree "$resource_heap_max_free"
  assert_property init.svc.netd running
  assert_property init.svc.statsd running
  assert_property init.svc.lmkd running
  assert_property service.sf.present_timestamp 0
  if [ "$graphics_backend" = software ]; then
    assert_property service.sf.prime_shader_cache false
  fi
  for required_service in jobscheduler uimode activity sensor_privacy media.audio_flinger media.audio_policy \
      stats gpu suspend_control suspend_control_internal android.system.suspend.ISystemSuspend/default; do
    service_status=$(docker exec "$container" service check "$required_service" 2>/dev/null | tr -d '\r')
    if [ "$service_status" != "Service $required_service: found" ]; then
      printf 'error: Android 15 required service %s is unavailable in %s: %s\n' \
        "$required_service" "$container" "${service_status:-<empty>}" >&2
      exit 1
    fi
  done
  if ! docker logs "$container" 2>&1 | grep -Fq \
      'ROYD: keeping native wake locks in-process without host kernel wake locks'; then
    printf 'error: Android 15 in-process wake-lock mode is not reported in %s\n' "$container" >&2
    exit 1
  fi
  suspend_dump=$(docker exec "$container" dumpsys suspend_control_internal 2>&1) || {
    printf 'error: Android 15 native wake-lock statistics dump failed in %s\n' "$container" >&2
    exit 1
  }
  if ! printf '%s\n' "$suspend_dump" | grep -Eq \
      'PowerManagerService\.[A-Za-z]+[[:space:]]*\|[[:space:]]*[0-9]+[[:space:]]*\|[[:space:]]*Native'; then
    printf 'error: Android 15 native wake-lock statistics are unavailable in %s\n' "$container" >&2
    exit 1
  fi
  docker exec "$container" sh -c '
    # royd-runtime-host-power-test
    suspend=$(pidof android.system.suspend-service) || exit 1
    case "$suspend" in ""|*[!0-9]*) exit 1 ;; esac
    ls "/proc/$suspend/fd" >/dev/null || exit 1
    count=0
    for descriptor in /proc/$suspend/fd/*; do
      target=$(readlink "$descriptor") || continue
      case "$target" in
        /sys/power/state|/sys/power/wakeup_count|/sys/power/wake_lock|/sys/power/wake_unlock)
          exit 1 ;;
      esac
      count=$((count + 1))
    done
    test "$count" -gt 0
  ' || {
    printf 'error: Android 15 SystemSuspend host-power descriptor isolation failed in %s\n' \
      "$container" >&2
    exit 1
  }
  if docker logs "$container" 2>&1 | grep -Eq \
      'suspend-service: error (opening|writing).* /sys/power/(state|wakeup_count|wake_lock|wake_unlock)(:|$)'; then
    printf 'error: Android 15 SystemSuspend attempted host power control in %s\n' "$container" >&2
    exit 1
  fi
  stats_dump=$(docker exec "$container" dumpsys stats --metadata 2>&1) || {
    printf 'error: Android 15 statsd Binder metadata dump failed in %s: %s\n' \
      "$container" "$stats_dump" >&2
    exit 1
  }
  if ! printf '%s\n' "$stats_dump" | grep -q '^Stats collection start second:'; then
    printf 'error: Android 15 statsd Binder metadata response is invalid in %s: %s\n' \
      "$container" "$stats_dump" >&2
    exit 1
  fi
  if ! docker logs "$container" 2>&1 | grep -Fq \
      'ROYD: suppressing statsd Binder caller SID request'; then
    printf 'error: Android 15 statsd container Binder SID mode is not reported in %s\n' \
      "$container" >&2
    exit 1
  fi
  if docker logs "$container" 2>&1 | grep -Eq \
      "StatsManagerService: (Failed to access statsd to register puller|StatsManager failed to)|associateClass: Expecting binder to have class 'android.os.IStatsd' but descriptor is actually ''"; then
    printf 'error: Android 15 statsd Binder registration failed in %s\n' "$container" >&2
    exit 1
  fi
  if ! docker logs "$container" 2>&1 | grep -Fq \
      'ROYD: not starting host-global GPU memory tracing'; then
    printf 'error: Android 15 container GPU-memory tracing policy is not reported in %s\n' "$container" >&2
    exit 1
  fi
  gpu_memory_dump=$(docker exec "$container" dumpsys gpu --gpumem 2>&1) || {
    printf 'error: Android 15 GPU-memory status dump failed in %s\n' "$container" >&2
    exit 1
  }
  if ! printf '%s\n' "$gpu_memory_dump" | grep -Fxq \
      'GPU memory tracing unavailable: host-global accounting is not container-scoped'; then
    printf 'error: Android 15 GPU-memory accounting is not explicitly unavailable in %s\n' "$container" >&2
    exit 1
  fi
  if [ "$hal_profile" = graphical ]; then
    gpu_stats_dump=$(docker exec "$container" dumpsys gpu --gpustats 2>&1) || {
      printf 'error: Android 15 GPU driver statistics dump failed in %s\n' "$container" >&2
      exit 1
    }
    if ! printf '%s\n' "$gpu_stats_dump" | grep -q '^driverPackageName = '; then
      printf 'error: Android 15 GPU driver statistics are unavailable in %s\n' "$container" >&2
      exit 1
    fi
  fi
  if docker logs "$container" 2>&1 | grep -Eq \
      'GpuMem[[:space:]]*: Failed to attach bpf program to gpu_mem/gpu_mem_total tracepoint|GpuMemTracer: Cannot initialize GpuMemTracer before GpuMem'; then
    printf 'error: Android 15 attempted host-global GPU-memory tracing in %s\n' "$container" >&2
    exit 1
  fi
  if ! docker logs "$container" 2>&1 | grep -Fq \
      'ROYD: not starting host-global GPU work tracing'; then
    printf 'error: Android 15 container GPU-work tracing policy is not reported in %s\n' \
      "$container" >&2
    exit 1
  fi
  gpu_work_dump=$(docker exec "$container" dumpsys gpu --gpuwork 2>&1) || {
    printf 'error: Android 15 GPU-work status dump failed in %s\n' "$container" >&2
    exit 1
  }
  if [ "$gpu_work_dump" != 'GPU work tracing unavailable: host-global accounting is not container-scoped' ]; then
    printf 'error: Android 15 GPU-work accounting is not explicitly unavailable in %s\n' \
      "$container" >&2
    exit 1
  fi
  if docker logs "$container" 2>&1 | grep -Eq \
      'GpuWork[[:space:]]*: (Failed to (attach bpf program to power/gpu_work_period tracepoint|create bpf map from /sys/fs/bpf/map_gpuWork_|retrieve pinned program from /sys/fs/bpf/prog_gpuWork_)|Initialized!)'; then
    printf 'error: Android 15 attempted host-global GPU-work tracing in %s\n' "$container" >&2
    exit 1
  fi
  for memory_event_marker in \
      'ROYD: not starting host-global OOM event listener' \
      'ROYD: using vmstat fallback without host-global memory-event tracing' \
      'Using vmstats for direct reclaim and kswapd detection'; do
    if ! docker logs "$container" 2>&1 | grep -Fq "$memory_event_marker"; then
      printf 'error: Android 15 memory-event container fallback is not reported in %s: %s\n' \
        "$container" "$memory_event_marker" >&2
      exit 1
    fi
  done
  if docker logs "$container" 2>&1 | grep -Eq \
      'memevent failed to attach bpf program to (oom/mark_victim|vmscan/mm_vmscan_)|OomConnection: failed waiting for OOM events|Failed to register (direct reclaim|kswapd) memevents'; then
    printf 'error: Android 15 attempted host-global memory-event tracing in %s\n' \
      "$container" >&2
    exit 1
  fi
  dropbox_status=$(docker exec "$container" service check dropbox 2>/dev/null | tr -d '\r')
  if [ "$dropbox_status" != 'Service dropbox: found' ]; then
    printf 'error: Android 15 DropBox service is unavailable in %s: %s\n' \
      "$container" "${dropbox_status:-<empty>}" >&2
    exit 1
  fi
  if docker logs "$container" 2>&1 | grep -Fq 'No service published for: dropbox'; then
    printf 'error: Android 15 recursively reported the unpublished DropBox service in %s\n' \
      "$container" >&2
    exit 1
  fi
  if docker logs "$container" 2>&1 | grep -Fq 'failed to fetch tether stats'; then
    printf 'error: Android 15 repeatedly queried unavailable idle tether counters in %s\n' \
      "$container" >&2
    exit 1
  fi
  if docker logs "$container" 2>&1 | grep -Eq \
      'NetlinkUtils: Received unexpected netlink message: NetlinkErrorMessage|InetDiagMessage: Failed to send netlink dump request or receive messages:.*EAGAIN'; then
    printf 'error: Android 15 repeated unavailable inet-diag socket dumps in %s\n' \
      "$container" >&2
    exit 1
  fi
  if docker logs "$container" 2>&1 | grep -Eq 'am_wtf.*SystemServiceRegistry'; then
    printf 'error: Android 15 emitted missing-service WTF diagnostics in %s\n' \
      "$container" >&2
    exit 1
  fi
  if docker logs "$container" 2>&1 | awk '
      /Outgoing transactions from this process must be FLAG_ONEWAY/ { remaining = 12 }
      remaining > 0 && /android\.os\.IServiceManager\$Stub\$Proxy\./ { found = 1; exit }
      remaining > 0 { remaining-- }
      END { exit found ? 0 : 1 }
    '; then
    printf 'error: Android 15 native ServiceManager proxy triggered a blocking-call WTF in %s\n' \
      "$container" >&2
    exit 1
  fi
  if docker logs "$container" 2>&1 | grep -Fq \
      "Fstab entries not found for '/system"; then
    printf 'error: Android 15 ART could not classify the OCI system overlay in %s\n' \
      "$container" >&2
    exit 1
  fi
  if docker logs "$container" 2>&1 | grep -Fq 'Failed to verity-protect'; then
    printf 'error: Android 15 attempted unavailable metadata fs-verity protection in %s\n' \
      "$container" >&2
    exit 1
  fi
  if docker logs "$container" 2>&1 | grep -Fq 'No mount point entry for /data'; then
    printf 'error: Android 15 queried an unavailable physical data-storage device in %s\n' "$container" >&2
    exit 1
  fi
  if docker logs "$container" 2>&1 | grep -Eq 'am_crash.*com\.android\.settings'; then
    printf 'error: Android 15 retained a Settings crash in %s\n' "$container" >&2
    exit 1
  fi
  if docker logs "$container" 2>&1 | grep -Eq 'libminijail\[[0-9]+\]: blocked syscall: memfd_create|Service .mediaextractor.*received signal (6|31)([^0-9]|$)'; then
    printf 'error: Android 15 retained a mediaextractor sandbox failure or service death in %s\n' "$container" >&2
    exit 1
  fi
  if docker logs "$container" 2>&1 | grep -Eq \
      'SetCgroup::ExecuteFor(Process|Task): failed to open /dev/(cpuctl|cpuset|blkio)/'; then
    printf 'error: Android 15 attempted unavailable legacy cgroup task profiles in %s\n' \
      "$container" >&2
    exit 1
  fi
  if docker logs "$container" 2>&1 | grep -Fq \
      "TaskPersister: File error accessing recents directory (directory doesn't exist?)."; then
    printf 'error: Android 15 recents cleanup could not list its directories in %s\n' \
      "$container" >&2
    exit 1
  fi
  if docker exec "$container" sh -c '
    # royd-runtime-legacy-cgroup-availability-test
    for root in /dev/cpuctl /dev/cpuset /dev/blkio; do
      [ -e "$root/cgroup.procs" ] || exit 0
    done
    exit 1
  '; then
    if ! docker logs "$container" 2>&1 | grep -Fq \
        'ROYD: skipping task-profile actions for unavailable legacy cgroup controllers'; then
      printf 'error: Android 15 did not report unavailable legacy cgroup task profiles in %s\n' \
        "$container" >&2
      exit 1
    fi
  fi
  docker exec "$container" sh -c '
    # royd-runtime-package-list-test
    test -s /data/system/packages.list
  ' || {
    printf 'error: Android 15 packages.list is missing or empty in %s\n' "$container" >&2
    exit 1
  }
  if docker logs "$container" 2>&1 | grep -Eq \
      'am_wtf.*PackageSettings.*Failed to (get SELinux context|set packages.list SELinux context)'; then
    printf 'error: Android 15 attempted unavailable packages.list SELinux context setup in %s\n' \
      "$container" >&2
    exit 1
  fi
  if docker logs "$container" 2>&1 | grep -Eq \
      'am_wtf.*CpuMonitorService|CpuMonitorService: Failed to initialize CPU info reader'; then
    printf 'error: Android 15 started its unavailable CPU frequency monitor in %s\n' \
      "$container" >&2
    exit 1
  fi
  if docker exec "$container" sh -c '
    # royd-runtime-cpu-residency-availability-test
    for policy in /sys/devices/system/cpu/cpufreq/policy*; do
      [ ! -d "$policy" ] || exit 1
    done
    [ ! -e /sys/devices/system/cpu/cpu0/cpufreq/stats/time_in_state ]
  '; then
    # BatteryStats can select per-UID frequency data without calling the legacy reader.
    # Its missing-file diagnostic is on demand, not a boot readiness marker.
    printf '%s\n' 'CPU frequency residency: unavailable (cpufreq policies and fallback interface absent)'
  fi
  if docker logs "$container" 2>&1 | grep -Eq \
      'KernelCpuSpeedReader: Failed to read cpu-freq: /sys/devices/system/cpu/cpu[0-9]+/cpufreq/stats/time_in_state: open failed: ENOENT'; then
    printf 'error: Android 15 repeated missing CPU-frequency residency diagnostics in %s\n' \
      "$container" >&2
    exit 1
  fi
  if docker logs "$container" 2>&1 | grep -Eq \
      'KernelCpuUidUserSysTimeReader: (Removing uids |failed to remove uids .* from uid_cputime module)'; then
    printf 'error: Android 15 attempted host-global UID CPU-stat cleanup in %s\n' \
      "$container" >&2
    exit 1
  fi
  # The cleanup policy marker is on demand, not a boot-readiness condition.
  cpu_time_dump=$(docker exec "$container" dumpsys cpuinfo 2>&1) || {
    printf 'error: Android 15 CPU-time status dump failed in %s\n' "$container" >&2
    exit 1
  }
  if ! printf '%s\n' "$cpu_time_dump" | grep -q '^CPU usage from ' || \
      ! printf '%s\n' "$cpu_time_dump" | grep -q '% TOTAL:'; then
    printf 'error: Android 15 CPU-time accounting response is invalid in %s\n' "$container" >&2
    exit 1
  fi
  if ! docker logs "$container" 2>&1 | grep -Fq \
      'ROYD: using unprivileged 2-second PSI windows for ActivityManager'; then
    printf 'error: Android 15 did not enable its unprivileged ActivityManager PSI monitor in %s\n' \
      "$container" >&2
    exit 1
  fi
  if docker logs "$container" 2>&1 | grep -Eq \
      'LowMemDetector: Failed to register psi trigger|libpsi:.*pressure/memory write failed'; then
    printf 'error: Android 15 ActivityManager PSI monitor failed to register in %s\n' \
      "$container" >&2
    exit 1
  fi
  docker exec "$container" sh -c '
    # royd-runtime-emulated-storage-test
    grep -F " /mnt rw," /proc/1/mountinfo | grep -Fq " - tmpfs tmpfs rw,"
    grep -F " /storage/emulated rw," /proc/1/mountinfo | grep -Fq " - fuse /dev/fuse rw,"
    test -d /storage/emulated/0
  ' || {
    printf 'error: Android 15 emulated storage is not mounted in %s\n' "$container" >&2
    exit 1
  }
  if docker logs "$container" 2>&1 | grep -Eq \
      'failed to create mount points|am_wtf.*StorageManagerService'; then
    printf 'error: Android 15 emulated storage mount failed in %s\n' "$container" >&2
    exit 1
  fi
  audio_pid=$(docker exec "$container" pidof audioserver 2>/dev/null) || audio_pid=
  case "$audio_pid" in
    ''|0|*[!0-9]*)
      printf 'error: Android 15 audioserver PID is unavailable in %s\n' "$container" >&2
      exit 1 ;;
  esac
  # The forwarding service uses threadtime. Attribute shared ServiceManager messages to
  # audioserver, including former instances identified by their own native log tag.
  audio_waits=$(docker logs "$container" 2>&1 | awk -v current="$audio_pid" '
    BEGIN { audio[current] = 1 }
    $3 ~ /^[0-9]+$/ && $6 == "audioserver:" { audio[$3] = 1 }
    $3 ~ /^[0-9]+$/ && $6 == "ServiceManagerCppClient:" &&
        $7 == "Waited" && $8 == "one" && $9 == "second" && $10 == "for" {
      waits[$3, $11] = 1
    }
    END {
      for (pid in audio) {
        if ((pid, "activity") in waits) print "activity"
        if ((pid, "sensor_privacy") in waits) print "sensor_privacy"
      }
    }
  ')
  if printf '%s\n' "$audio_waits" | grep -Fxq activity; then
    printf 'error: Android 15 blocked audioserver on unpublished ActivityManager in %s\n' \
      "$container" >&2
    exit 1
  fi
  if printf '%s\n' "$audio_waits" | grep -Fxq sensor_privacy; then
    printf 'error: Android 15 blocked audioserver on unpublished sensor privacy in %s\n' \
      "$container" >&2
    exit 1
  fi
  watchdog_dump=$(docker exec "$container" timeout 15 dumpsys system_server_dumper --name Watchdog) || {
    printf 'error: Android 15 Watchdog state is unavailable in %s\n' "$container" >&2
    exit 1
  }
  if ! printf '%s\n' "$watchdog_dump" | awk '
      /^[[:space:]]*RoydHostSysRq=/ {
        count++
        if ($0 !~ /^[[:space:]]*RoydHostSysRq=disabled$/) bad=1
      }
      END { exit (!bad && count == 1) ? 0 : 1 }
    '; then
    printf 'error: Android 15 Watchdog host SysRq diagnostics are not disabled in %s\n' "$container" >&2
    exit 1
  fi
  if docker logs "$container" 2>&1 | grep -Fq 'Watchdog: Failed to write to /proc/sysrq-trigger'; then
    printf 'error: Android 15 Watchdog attempted host SysRq diagnostics in %s\n' "$container" >&2
    exit 1
  fi
  if docker logs "$container" 2>&1 | grep -Fq 'Watchdog: WAITED_UNTIL_PRE_WATCHDOG'; then
    printf 'error: Android 15 triggered a SystemServer pre-watchdog in %s\n' "$container" >&2
    exit 1
  fi
  assert_property media.c2.hal.selection aidl
  assert_property debug.stagefright.c2inputsurface -1
  assert_property debug.stagefright.c2-poolmask 786432
  codec_store=$(docker exec "$container" \
    dumpsys android.hardware.media.c2.IComponentStore/software 2>/dev/null) || {
    printf 'error: Android 15 software Codec2 store is unavailable in %s\n' "$container" >&2
    exit 1
  }
  for component in c2.android.avc.encoder c2.android.opus.encoder; do
    printf '%s\n' "$codec_store" | grep -Fq "name: $component" || {
      printf 'error: Android 15 software Codec2 store omits %s in %s\n' "$component" "$container" >&2
      exit 1
    }
  done
  docker exec "$container" sh -c '
    # royd-runtime-cgroup-test
    test "$(stat -c %u:%g:%a /sys/fs/cgroup/royd)" = 1000:1000:775
    test "$(cat /proc/1/cgroup)" = 0::/royd/init
    grep -qw memory /sys/fs/cgroup/royd/cgroup.controllers
    grep -qw memory /sys/fs/cgroup/royd/cgroup.subtree_control
    system_server=$(pidof system_server) || exit 1
    system_group=$(sed -n "s/^0:://p" "/proc/$system_server/cgroup")
    case "$system_group" in
      /royd/uid_1000/pid_*) ;;
      *) exit 1 ;;
    esac
    test -f "/sys/fs/cgroup$system_group/memory.low"
  ' || {
    printf 'error: Android 15 delegated cgroup-v2 subtree is not ready in %s\n' "$container" >&2
    exit 1
  }
fi

for display_property in width height dpi fps; do
  value=$(docker exec "$container" getprop "vendor.royd.display.$display_property" 2>/dev/null | tr -d '\r')
  case "$value" in
    ''|*[!0-9]*|0)
      printf 'error: vendor.royd.display.%s is not a positive integer in %s: %s\n' "$display_property" "$container" "${value:-<empty>}" >&2
      exit 1
      ;;
  esac
  case "$display_property" in
    width) display_width=$value ;;
    height) display_height=$value ;;
    dpi) display_dpi=$value ;;
  esac
done

if [ "$sdk" = 35 ] && [ "$graphics_backend" = software ]; then
  display_identity=$(docker exec "$container" dumpsys SurfaceFlinger --display-id 2>&1) || {
    printf 'error: Android 15 display-identity dump failed in %s\n' "$container" >&2
    exit 1
  }
  if [ "$display_identity" != 'Display 0 (HWC display 1): no display identification data' ]; then
    printf 'error: Android 15 software display lost its legacy identity in %s\n' "$container" >&2
    exit 1
  fi
  if ! docker logs "$container" 2>&1 | grep -Fq 'HWComposer: Switching to legacy multi-display mode'; then
    printf 'error: Android 15 software legacy-display fallback is not reported in %s\n' \
      "$container" >&2
    exit 1
  fi
  if docker logs "$container" 2>&1 | grep -Fq \
      "HwcComposer: getDisplayIdentificationData failed Status(-8, EX_SERVICE_SPECIFIC): '8:"; then
    printf 'error: Android 15 optional display identification was reported as a failure in %s\n' \
      "$container" >&2
    exit 1
  fi
fi

if [ "$sdk" = 35 ] && [ "$hal_profile" = graphical ]; then
  assert_property ro.sf.lcd_density "$display_dpi"
  effective_density=$(docker exec "$container" wm density 2>&1) || {
    printf 'error: Android 15 effective display density query failed in %s\n' "$container" >&2
    exit 1
  }
  if [ "$effective_density" != "Physical density: $display_dpi" ]; then
    printf 'error: Android 15 effective display density does not match %s dpi in %s: %s\n' \
      "$display_dpi" "$container" "$effective_density" >&2
    exit 1
  fi
  if docker logs "$container" 2>&1 | grep -Fq 'ro.sf.lcd_density must be defined as a build property'; then
    printf 'error: Android 15 SurfaceFlinger used its fallback display density in %s\n' "$container" >&2
    exit 1
  fi
  printf 'Android 15 effective display density: %s dpi\n' "$display_dpi"

  appwidget_status=$(docker exec "$container" service check appwidget 2>/dev/null | tr -d '\r')
  if [ "$appwidget_status" != 'Service appwidget: found' ]; then
    printf 'error: Android 15 AppWidget service is unavailable in %s: %s\n' \
      "$container" "${appwidget_status:-<empty>}" >&2
    exit 1
  fi
  docker exec "$container" pm list features 2>/dev/null | \
    grep -Fxq 'feature:android.software.app_widgets' || {
    printf 'error: Android 15 app-widget feature is not declared in %s\n' "$container" >&2
    exit 1
  }
  docker exec "$container" sh -c '
    # royd-runtime-launcher-test
    input keyevent KEYCODE_WAKEUP
    wm dismiss-keyguard
    input keyevent KEYCODE_HOME
    sleep 2
    first=$(pidof com.android.launcher3) || exit 1
    sleep 4
    second=$(pidof com.android.launcher3) || exit 1
    [ "$first" = "$second" ]
  ' || {
    printf 'error: Android 15 Launcher3 did not remain stable after unlock in %s\n' "$container" >&2
    exit 1
  }

  docker exec "$container" sh -c '
    # royd-runtime-memcg-path-test
    launcher=$(pidof com.android.launcher3) || exit 1
    launcher_group=$(sed -n "s/^0:://p" "/proc/$launcher/cgroup")
    memory_low=$(cat "/sys/fs/cgroup$launcher_group/memory.low") || exit 1
    case "$memory_low" in
      ""|*[!0-9]*) exit 1 ;;
    esac
    [ "$memory_low" -gt 0 ]
  ' || {
    printf 'error: Android 15 per-process memory.low policy is not active in %s\n' "$container" >&2
    exit 1
  }
  if docker logs "$container" 2>&1 | grep -Fq '/sys/fs/cgroup/royd/royd/'; then
    printf 'error: Android 15 duplicated its delegated cgroup root in %s\n' "$container" >&2
    exit 1
  fi

  docker exec "$container" sh -c '
    # royd-runtime-webview-cgroup-test
    before=$(pidof system_server) || exit 1
    trap '\''am force-stop org.chromium.webview_shell >/dev/null 2>&1 || true'\'' EXIT INT TERM
    am start -W -n org.chromium.webview_shell/.WebViewBrowserActivity >/dev/null
    sleep 4
    after=$(pidof system_server) || exit 1
    [ "$before" = "$after" ]
    pidof org.chromium.webview_shell >/dev/null
  ' || {
    printf 'error: Android 15 WebView process groups restarted system_server in %s\n' "$container" >&2
    exit 1
  }

  "$script_dir/assert-app-lifecycle.sh" "$container"

  docker exec "$container" sh -c '
    # royd-runtime-about-phone-test
    before=$(pidof system_server) || exit 1
    trap '\''input keyevent KEYCODE_HOME >/dev/null 2>&1 || true'\'' EXIT INT TERM
    # Select the page itself, not another page above it in an existing Settings task.
    launch=$(am start -W --activity-clear-top -a android.settings.DEVICE_INFO_SETTINGS) || exit 1
    printf "%s\n" "$launch"
    printf "%s\n" "$launch" | grep -Fxq "Status: ok" || exit 1
    printf "%s\n" "$launch" | grep -Fxq \
      "Activity: com.android.settings/.Settings\$MyDeviceInfoActivity" || exit 1
    first=$(pidof com.android.settings) || exit 1
    sleep 4
    second=$(pidof com.android.settings) || exit 1
    [ "$first" = "$second" ] || exit 1
    after=$(pidof system_server) || exit 1
    [ "$before" = "$after" ]
  ' || {
    printf 'error: Android 15 About-phone activity did not remain stable in %s\n' \
      "$container" >&2
    exit 1
  }
  if docker logs "$container" 2>&1 | grep -Eq 'am_wtf.*SystemServiceRegistry'; then
    printf 'error: Android 15 About-phone workload emitted missing-service WTF diagnostics in %s\n' \
      "$container" >&2
    exit 1
  fi

  recents_directories=$(docker exec "$container" sh -c '
    # royd-runtime-recents-persistence-test
    am write >/dev/null || exit 1
    test -d /data/system_ce/0 || exit 1
    test -s /data/system_de/0/persisted_taskIds.txt || exit 1
    found=0
    for task in /data/system_ce/0/recent_tasks/*_task.xml; do
      if [ -s "$task" ]; then found=1; fi
    done
    test "$found" = 1 || exit 1
    if [ ! -e /data/system_ce/0/recent_images ]; then
      printf "%s\n" uncreated
    else
      printf "%s\n" present
    fi
  ') || {
    printf 'error: Android 15 recent tasks were not persisted after the workload in %s\n' \
      "$container" >&2
    exit 1
  }
  case "$recents_directories" in
    uncreated)
      docker logs "$container" 2>&1 | grep -Fq \
        'ROYD: no obsolete files in uncreated recents directories' || {
        printf 'error: Android 15 uncreated recents-directory mode is not reported in %s\n' \
          "$container" >&2
        exit 1
      }
      ;;
    present) ;;
    *) printf 'error: invalid Android 15 recents-directory state in %s\n' "$container" >&2; exit 1 ;;
  esac
  if docker logs "$container" 2>&1 | grep -Fq \
      "TaskPersister: File error accessing recents directory (directory doesn't exist?)."; then
    printf 'error: Android 15 recents cleanup could not list its directories in %s\n' \
      "$container" >&2
    exit 1
  fi

  capture_width=$(( (display_width + 7) / 8 * 8 ))
  capture_script=$(cat "$script_dir/android15-display-capture.sh")
  test -n "$capture_script"
  docker exec "$container" timeout 120 sh -c "$capture_script" sh "$capture_width" "$display_height" || {
    printf 'error: Android 15 graphical capture/MediaStore validation failed in %s\n' "$container" >&2
    exit 1
  }
  if docker logs "$container" 2>&1 | grep -Eq \
      '(Trouble scanning|Failed to visit|Requested path) /(data/local/tmp/royd-runtime-video-test\.mp4|storage/emulated/0/Movies/royd-runtime-video-test\.[[:alnum:].-]+\.mp4)'; then
    printf 'error: Android 15 display capture emitted media-scanner failures in %s\n' "$container" >&2
    exit 1
  fi
  if docker logs "$container" 2>&1 | grep -Fq 'Invalid present fence'; then
    printf 'error: Android 15 SurfaceFlinger received an invalid present fence in %s\n' \
      "$container" >&2
    exit 1
  fi
fi

docker exec "$container" sh -c '[ -c /dev/binder ] && [ -c /dev/hwbinder ] && [ -c /dev/vndbinder ]' || {
  printf 'error: conventional Binder device paths are not ready in %s\n' "$container" >&2
  exit 1
}

docker exec "$container" sh -c "grep -q ' /dev/royd-binderfs binder ' /proc/mounts" || {
  printf 'error: private binderfs is not mounted at /dev/royd-binderfs in %s\n' "$container" >&2
  exit 1
}

docker logs "$container" 2>&1 | grep -Fq "$allocator_readiness" || {
  printf 'error: royd graphics allocator readiness diagnostic is missing from logs for %s\n' "$container" >&2
  exit 1
}

case "$graphics_backend" in
  software) readiness='[royd] graphics: software renderer selected' ;;
  host-gpu-*) readiness="[royd] graphics: host GPU renderer selected ($graphics_backend via " ;;
esac
docker logs "$container" 2>&1 | grep -Fq "$readiness" || {
  printf 'error: graphics readiness diagnostic is missing from logs for %s\n' "$container" >&2
  exit 1
}

docker logs "$container" 2>&1 | grep -Fq '[royd] display: early configuration' || {
  printf 'error: early display diagnostic is missing from logs for %s\n' "$container" >&2
  exit 1
}

docker logs "$container" 2>&1 | grep -Fq '[royd] boot-watchdog: armed timeout=' || {
  printf 'error: boot watchdog arm diagnostic is missing from logs for %s\n' "$container" >&2
  exit 1
}

docker logs "$container" 2>&1 | grep -Fq '[royd] boot-watchdog: boot completed after ' || {
  printf 'error: boot watchdog completion diagnostic is missing from logs for %s\n' "$container" >&2
  exit 1
}

docker logs "$container" 2>&1 | grep -Fq '[royd] binderfs: ready' || {
  printf 'error: binderfs readiness diagnostic is missing from logs for %s\n' "$container" >&2
  exit 1
}

if [ "$sdk" = 35 ]; then
  if ! docker logs "$container" 2>&1 | grep -Fq '[royd] display: runtime configuration validated'; then
    printf 'error: Android 15 display runtime configuration was not validated in %s\n' "$container" >&2
    exit 1
  fi
  if docker logs "$container" 2>&1 | grep -Fq \
      'display: runtime config missing or invalid, using profile defaults'; then
    printf 'error: Android 15 display bootstrap rejected the runtime configuration in %s\n' \
      "$container" >&2
    exit 1
  fi
  if ! docker logs "$container" 2>&1 | grep -Fq \
      'ROYD: Binder freezing disabled: PID namespace safety is unqualified'; then
    printf 'error: Android 15 Binder-freezer isolation mode is not reported in %s\n' "$container" >&2
    exit 1
  fi
  freezer_dump=$(docker exec "$container" dumpsys activity settings 2>&1) || {
    printf 'error: Android 15 app-freezer settings dump failed in %s\n' "$container" >&2
    exit 1
  }
  if ! printf '%s\n' "$freezer_dump" | grep -Eq '^[[:space:]]*use_freezer=false[[:space:]]*$' || \
      ! printf '%s\n' "$freezer_dump" | grep -Eq '^[[:space:]]*Apps frozen: 0[[:space:]]*$'; then
    printf 'error: Android 15 cached-app freezer is not disabled in %s\n' "$container" >&2
    exit 1
  fi
  if docker logs "$container" 2>&1 | grep -Eq \
      'Freezer[[:space:]]*: Unable to read freezer info|ActivityManager[[:space:]]*: Unable to (freeze|unfreeze|quick unfreeze) binder for'; then
    printf 'error: Android 15 attempted unqualified Binder freezer operations in %s\n' "$container" >&2
    exit 1
  fi
fi

if [ "$sdk" = 35 ]; then
  "$script_dir/assert-app-responsiveness.sh" "$container"
fi

printf 'Runtime checks passed: %s\n' "$container"
