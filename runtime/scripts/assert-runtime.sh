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
