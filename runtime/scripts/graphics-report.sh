#!/bin/sh
set -eu

container=${1:-royd}

command -v docker >/dev/null 2>&1 || {
  printf '%s\n' 'error: docker is required for graphics reporting' >&2
  exit 1
}

docker inspect "$container" >/dev/null 2>&1 || {
  printf 'error: container not found: %s\n' "$container" >&2
  exit 1
}

prop() {
  docker exec "$container" getprop "$1" 2>/dev/null | tr -d '\r'
}

printf '# royd graphics report\n\n'
printf 'Container: `%s`\n\n' "$container"
printf '| Property | Value |\n'
printf '| --- | --- |\n'
printf '| `ro.vendor.royd.graphics_backend` | `%s` |\n' "$(prop ro.vendor.royd.graphics_backend)"
printf '| `vendor.royd.graphics.mode` | `%s` |\n' "$(prop vendor.royd.graphics.mode)"
printf '| `vendor.royd.graphics.allocator` | `%s` |\n' "$(prop vendor.royd.graphics.allocator)"
printf '| `vendor.royd.graphics.composer` | `%s` |\n' "$(prop vendor.royd.graphics.composer)"
printf '| `ro.hardware.egl` | `%s` |\n' "$(prop ro.hardware.egl)"
printf '| `ro.hardware.gralloc` | `%s` |\n' "$(prop ro.hardware.gralloc)"
printf '| `ro.hardware.hwcomposer` | `%s` |\n' "$(prop ro.hardware.hwcomposer)"
printf '\n## Installed graphics modules\n\n```text\n'
docker exec "$container" sh -c 'ls -l /vendor/lib*/hw/gralloc.*.so /vendor/lib*/hw/hwcomposer.default.so /vendor/lib*/egl/libGLES_mesa.so 2>/dev/null || true'
printf '```\n\n## SurfaceFlinger\n\n```text\n'
docker exec "$container" sh -c 'getprop init.svc.surfaceflinger; dumpsys SurfaceFlinger --display-id 2>/dev/null || dumpsys SurfaceFlinger 2>/dev/null | head -n 120 || true'
printf '```\n'
