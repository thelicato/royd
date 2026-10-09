#!/bin/sh
set -eu

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
assert_property ro.config.low_ram true
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
  assert_property init.svc.netd running
  assert_property service.sf.present_timestamp 0
  for required_service in jobscheduler uimode; do
    service_status=$(docker exec "$container" service check "$required_service" 2>/dev/null | tr -d '\r')
    if [ "$service_status" != "Service $required_service: found" ]; then
      printf 'error: Android 15 required service %s is unavailable in %s: %s\n' \
        "$required_service" "$container" "${service_status:-<empty>}" >&2
      exit 1
    fi
  done
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
  esac
done

if [ "$sdk" = 35 ] && [ "$hal_profile" = graphical ]; then
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

  capture_width=$(( (display_width + 7) / 8 * 8 ))
  docker exec "$container" sh -c '
    capture=/data/local/tmp/royd-runtime-video-test.mp4
    trap '\''rm -f "$capture"'\'' EXIT INT TERM
    rm -f "$capture"
    cmd power wakeup
    sleep 1
    screenrecord --display-id 0 --size "${1}x${2}" --time-limit 2 "$capture" >/dev/null 2>&1
    test -s "$capture"
  ' sh "$capture_width" "$display_height" || {
    printf 'error: Android 15 graphical capture produced no H.264 frames in %s\n' "$container" >&2
    exit 1
  }
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

printf 'Runtime checks passed: %s\n' "$container"
