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
    if [ "$1" = sh ] && [ "$2" = -c ]; then
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

printf '%s\n' 'Runtime version-specific assertion contract test passed'
