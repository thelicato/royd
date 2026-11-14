#!/bin/sh
set -eu

# Existing Android 15 failure signatures, checked against one complete history.
# Positive readiness and capability checks remain in assert-runtime.sh.
container=${1:-royd}
graphics_backend=${2:-software}
hal_profile=${3:-graphical}
case "$graphics_backend" in software|host-gpu-generic|host-gpu-intel) ;; *)
  printf 'error: unsupported graphics backend for log history: %s\n' "$graphics_backend" >&2
  exit 1 ;;
esac
case "$hal_profile" in graphical|headless) ;; *)
  printf 'error: unsupported HAL profile for log history: %s\n' "$hal_profile" >&2
  exit 1 ;;
esac

audio_pid=$(docker exec "$container" pidof audioserver 2>/dev/null) || audio_pid=
case "$audio_pid" in
  ''|0|*[!0-9]*)
    printf 'error: Android 15 audioserver PID is unavailable in %s\n' "$container" >&2
    exit 1 ;;
esac
history=$(mktemp)
trap 'rm -f "$history"' EXIT
trap 'exit 1' HUP INT TERM
# Keep stdout and stderr together, including init diagnostics. A partial failed
# read must never be accepted because its earlier lines contain valid markers.
if ! docker logs "$container" >"$history" 2>&1; then
  printf 'error: could not read Android 15 runtime failure history in %s\n' "$container" >&2
  exit 1
fi

if grep -Fq \
    'ROYD: leaving the active network stats map unchanged because the PF_KEY RCU barrier is unavailable' <"$history"; then
  printf 'error: Android 15 froze UID statistics instead of completing RCU-protected rotation in %s\n' "$container" >&2
  exit 1
fi
if grep -Eq 'synchronizeKernelRCU( probe)? failed' <"$history"; then
  printf 'error: Android 15 UID statistics RCU barrier failed in %s\n' "$container" >&2
  exit 1
fi
if grep -Eq \
    'suspend-service: error (opening|writing).* /sys/power/(state|wakeup_count|wake_lock|wake_unlock)(:|$)' <"$history"; then
  printf 'error: Android 15 SystemSuspend attempted host power control in %s\n' "$container" >&2
  exit 1
fi
if grep -Eq \
    "StatsManagerService: (Failed to access statsd to register puller|StatsManager failed to)|associateClass: Expecting binder to have class 'android.os.IStatsd' but descriptor is actually ''" <"$history"; then
  printf 'error: Android 15 statsd Binder registration failed in %s\n' "$container" >&2
  exit 1
fi
if grep -Eq \
    'GpuMem[[:space:]]*: Failed to attach bpf program to gpu_mem/gpu_mem_total tracepoint|GpuMemTracer: Cannot initialize GpuMemTracer before GpuMem' <"$history"; then
  printf 'error: Android 15 attempted host-global GPU-memory tracing in %s\n' "$container" >&2
  exit 1
fi
if grep -Eq \
    'GpuWork[[:space:]]*: (Failed to (attach bpf program to power/gpu_work_period tracepoint|create bpf map from /sys/fs/bpf/map_gpuWork_|retrieve pinned program from /sys/fs/bpf/prog_gpuWork_)|Initialized!)' <"$history"; then
  printf 'error: Android 15 attempted host-global GPU-work tracing in %s\n' "$container" >&2
  exit 1
fi
if grep -Eq \
    'memevent failed to attach bpf program to (oom/mark_victim|vmscan/mm_vmscan_)|OomConnection: failed waiting for OOM events|Failed to register (direct reclaim|kswapd) memevents' <"$history"; then
  printf 'error: Android 15 attempted host-global memory-event tracing in %s\n' \
    "$container" >&2
  exit 1
fi
if grep -Fq 'No service published for: dropbox' <"$history"; then
  printf 'error: Android 15 recursively reported the unpublished DropBox service in %s\n' \
    "$container" >&2
  exit 1
fi
if grep -Fq 'failed to fetch tether stats' <"$history"; then
  printf 'error: Android 15 repeatedly queried unavailable idle tether counters in %s\n' \
    "$container" >&2
  exit 1
fi
if grep -Eq \
    'NetlinkUtils: Received unexpected netlink message: NetlinkErrorMessage|InetDiagMessage: Failed to send netlink dump request or receive messages:.*EAGAIN' <"$history"; then
  printf 'error: Android 15 repeated unavailable inet-diag socket dumps in %s\n' \
    "$container" >&2
  exit 1
fi
if grep -Eq 'am_wtf.*SystemServiceRegistry' <"$history"; then
  printf 'error: Android 15 emitted missing-service WTF diagnostics in %s\n' \
    "$container" >&2
  exit 1
fi
if awk '
    /Outgoing transactions from this process must be FLAG_ONEWAY/ { remaining = 12 }
    remaining > 0 && /android\.os\.IServiceManager\$Stub\$Proxy\./ { found = 1; exit }
    remaining > 0 { remaining-- }
    END { exit found ? 0 : 1 }
  ' <"$history"; then
  printf 'error: Android 15 native ServiceManager proxy triggered a blocking-call WTF in %s\n' \
    "$container" >&2
  exit 1
fi
if grep -Fq \
    "Fstab entries not found for '/system" <"$history"; then
  printf 'error: Android 15 ART could not classify the OCI system overlay in %s\n' \
    "$container" >&2
  exit 1
fi
if grep -Fq 'Failed to verity-protect' <"$history"; then
  printf 'error: Android 15 attempted unavailable metadata fs-verity protection in %s\n' \
    "$container" >&2
  exit 1
fi
if grep -Fq 'No mount point entry for /data' <"$history"; then
  printf 'error: Android 15 queried an unavailable physical data-storage device in %s\n' "$container" >&2
  exit 1
fi
if grep -Eq 'am_crash.*com\.android\.settings' <"$history"; then
  printf 'error: Android 15 retained a Settings crash in %s\n' "$container" >&2
  exit 1
fi
if grep -Eq 'libminijail\[[0-9]+\]: blocked syscall: memfd_create|Service .mediaextractor.*received signal (6|31)([^0-9]|$)' <"$history"; then
  printf 'error: Android 15 retained a mediaextractor sandbox failure or service death in %s\n' "$container" >&2
  exit 1
fi
if grep -Eq \
    'SetCgroup::ExecuteFor(Process|Task): failed to open /dev/(cpuctl|cpuset|blkio)/' <"$history"; then
  printf 'error: Android 15 attempted unavailable legacy cgroup task profiles in %s\n' \
    "$container" >&2
  exit 1
fi
if grep -Fq \
    "TaskPersister: File error accessing recents directory (directory doesn't exist?)." <"$history"; then
  printf 'error: Android 15 recents cleanup could not list its directories in %s\n' \
    "$container" >&2
  exit 1
fi
if grep -Eq \
    'am_wtf.*PackageSettings.*Failed to (get SELinux context|set packages.list SELinux context)' <"$history"; then
  printf 'error: Android 15 attempted unavailable packages.list SELinux context setup in %s\n' \
    "$container" >&2
  exit 1
fi
if grep -Eq \
    'am_wtf.*CpuMonitorService|CpuMonitorService: Failed to initialize CPU info reader' <"$history"; then
  printf 'error: Android 15 started its unavailable CPU frequency monitor in %s\n' \
    "$container" >&2
  exit 1
fi
if grep -Eq \
    'KernelCpuSpeedReader: Failed to read cpu-freq: /sys/devices/system/cpu/cpu[0-9]+/cpufreq/stats/time_in_state: open failed: ENOENT' <"$history"; then
  printf 'error: Android 15 repeated missing CPU-frequency residency diagnostics in %s\n' \
    "$container" >&2
  exit 1
fi
if grep -Eq \
    'KernelCpuUidUserSysTimeReader: (Removing uids |failed to remove uids .* from uid_cputime module)' <"$history"; then
  printf 'error: Android 15 attempted host-global UID CPU-stat cleanup in %s\n' \
    "$container" >&2
  exit 1
fi
if grep -Eq \
    'LowMemDetector: Failed to register psi trigger|libpsi:.*pressure/memory write failed' <"$history"; then
  printf 'error: Android 15 ActivityManager PSI monitor failed to register in %s\n' \
    "$container" >&2
  exit 1
fi
if grep -Eq \
    'failed to create mount points|am_wtf.*StorageManagerService' <"$history"; then
  printf 'error: Android 15 emulated storage mount failed in %s\n' "$container" >&2
  exit 1
fi
# The forwarding service uses threadtime. Attribute shared ServiceManager messages to
# audioserver, including former instances identified by their own native log tag.
audio_waits=$(awk -v current="$audio_pid" '
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
' <"$history")
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
if grep -Eq \
    'TcpSocketTracker[^:]*: Expect to get family (2|10) SOCK_DIAG_BY_FAMILY message but get 2([^0-9]|$)' <"$history"; then
  printf 'error: Android 15 misclassified a TCP diagnostic netlink error in %s\n' "$container" >&2
  exit 1
fi
if grep -Fq 'Watchdog: Failed to write to /proc/sysrq-trigger' <"$history"; then
  printf 'error: Android 15 Watchdog attempted host SysRq diagnostics in %s\n' "$container" >&2
  exit 1
fi
if grep -Eq 'Watchdog[[:space:]]*: (WAITED_UNTIL_PRE_WATCHDOG|ROYD: pre-watchdog (blocked checkers:|checker timing:))' <"$history"; then
  printf 'error: Android 15 triggered a SystemServer pre-watchdog in %s\n' "$container" >&2
  exit 1
fi
if grep -Fq \
    'display: runtime config missing or invalid, using profile defaults' <"$history"; then
  printf 'error: Android 15 display bootstrap rejected the runtime configuration in %s\n' \
    "$container" >&2
  exit 1
fi
if grep -Eq \
    'Freezer[[:space:]]*: Unable to read freezer info|ActivityManager[[:space:]]*: Unable to (freeze|unfreeze|quick unfreeze) binder for' <"$history"; then
  printf 'error: Android 15 attempted unqualified Binder freezer operations in %s\n' "$container" >&2
  exit 1
fi

if [ "$graphics_backend" = software ]; then
  if grep -Fq \
      "HwcComposer: getDisplayIdentificationData failed Status(-8, EX_SERVICE_SPECIFIC): '8:" <"$history"; then
    printf 'error: Android 15 optional display identification was reported as a failure in %s\n' \
      "$container" >&2
    exit 1
  fi
fi

if [ "$hal_profile" = graphical ]; then
  if grep -Fq 'ro.sf.lcd_density must be defined as a build property' <"$history"; then
    printf 'error: Android 15 SurfaceFlinger used its fallback display density in %s\n' "$container" >&2
    exit 1
  fi
  if grep -Fq '/sys/fs/cgroup/royd/royd/' <"$history"; then
    printf 'error: Android 15 duplicated its delegated cgroup root in %s\n' "$container" >&2
    exit 1
  fi
  if grep -Eq \
      '(Trouble scanning|Failed to visit|Requested path) /(data/local/tmp/royd-runtime-video-test\.mp4|storage/emulated/0/Movies/royd-runtime-video-test\.[[:alnum:].-]+\.mp4)' <"$history"; then
    printf 'error: Android 15 display capture emitted media-scanner failures in %s\n' "$container" >&2
    exit 1
  fi
  if grep -Fq 'Invalid present fence' <"$history"; then
    printf 'error: Android 15 SurfaceFlinger received an invalid present fence in %s\n' \
      "$container" >&2
    exit 1
  fi
fi
