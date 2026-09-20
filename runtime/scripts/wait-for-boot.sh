#!/bin/sh
set -eu

container=${1:-royd}
timeout=${2:-${ROYD_BOOT_TIMEOUT:-180}}

case "$timeout" in
  ''|*[!0-9]*)
    printf 'error: boot timeout must be a whole number of seconds: %s\n' "$timeout" >&2
    exit 2
    ;;
esac

command -v docker >/dev/null 2>&1 || {
  printf '%s\n' 'error: docker is required for runtime validation' >&2
  exit 1
}

docker inspect "$container" >/dev/null 2>&1 || {
  printf 'error: container not found: %s\n' "$container" >&2
  exit 1
}

started=$(date +%s)
printf 'Waiting up to %s seconds for Android to boot in %s\n' "$timeout" "$container"
while :; do
  running=$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null || printf 'false')
  if [ "$running" != 'true' ]; then
    printf 'error: container stopped before Android completed boot: %s\n' "$container" >&2
    docker logs --tail 100 "$container" >&2 2>/dev/null || true
    exit 1
  fi

  completed=$(docker exec "$container" getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)
  if [ "$completed" = '1' ]; then
    printf 'Android boot completed in %s\n' "$container"
    exit 0
  fi

  now=$(date +%s)
  elapsed=$((now - started))
  if [ "$elapsed" -ge "$timeout" ]; then
    printf 'error: Android did not complete boot within %s seconds: %s\n' "$timeout" "$container" >&2
    docker logs --tail 100 "$container" >&2 2>/dev/null || true
    exit 1
  fi
  sleep 2
done
