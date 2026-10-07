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
    if [ "$1" = getprop ]; then
      property=$2
      case "$property" in
        ro.build.version.sdk) value=$MOCK_SDK ;;
        sys.boot_completed) value=1 ;;
        ro.config.low_ram) value=true ;;
        init.svc.royd-logcat|init.svc.adbd) value=running ;;
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
    if [ "$1" = service ] && [ "$2" = check ] && [ "$3" = appwidget ]; then
      if [ "${MOCK_BAD_APPWIDGET:-0}" = 1 ]; then
        printf '%s\n' 'Service appwidget: not found'
      else
        printf '%s\n' 'Service appwidget: found'
      fi
      exit 0
    fi
    if [ "$1" = pm ] && [ "$2" = list ] && [ "$3" = features ]; then
      [ "${MOCK_BAD_APPWIDGET_FEATURE:-0}" = 1 ] || \
        printf '%s\n' 'feature:android.software.app_widgets'
      exit 0
    fi
    if [ "$1" = sh ] && [ "$2" = -c ]; then
      case "$3" in
        *royd-runtime-launcher-test*)
          [ "${MOCK_BAD_LAUNCHER:-0}" != 1 ] || exit 1
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

printf '%s\n' 'Runtime version-specific assertion contract test passed'
