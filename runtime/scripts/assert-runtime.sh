#!/bin/sh
set -eu

container=${1:-royd}

command -v docker >/dev/null 2>&1 || {
  printf '%s\n' 'error: docker is required for runtime validation' >&2
  exit 1
}

docker inspect "$container" >/dev/null 2>&1 || {
  printf 'error: container not found: %s\n' "$container" >&2
  exit 1
}

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
assert_property vendor.royd.graphics.mode software
assert_property vendor.royd.graphics.allocator gralloc0-memfd
assert_property ro.hardware.gralloc royd
assert_property ro.hardware.hwcomposer default
assert_property vendor.royd.host.memfd available

docker exec "$container" sh -c '[ -c /dev/binder ] && [ -c /dev/hwbinder ] && [ -c /dev/vndbinder ]' || {
  printf 'error: conventional Binder device paths are not ready in %s\n' "$container" >&2
  exit 1
}

docker exec "$container" sh -c "grep -q ' /dev/binderfs binder ' /proc/mounts" || {
  printf 'error: binderfs is not mounted at /dev/binderfs in %s\n' "$container" >&2
  exit 1
}

docker logs "$container" 2>&1 | grep -Fq '[royd] graphics: allocator gralloc0-memfd ready' || {
  printf 'error: royd graphics allocator readiness diagnostic is missing from logs for %s\n' "$container" >&2
  exit 1
}

docker logs "$container" 2>&1 | grep -Fq '[royd] graphics: software renderer selected' || {
  printf 'error: software graphics readiness diagnostic is missing from logs for %s\n' "$container" >&2
  exit 1
}

docker logs "$container" 2>&1 | grep -Fq '[royd] binderfs: ready' || {
  printf 'error: binderfs readiness diagnostic is missing from logs for %s\n' "$container" >&2
  exit 1
}

printf 'Runtime checks passed: %s\n' "$container"
