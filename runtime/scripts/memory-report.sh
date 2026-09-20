#!/bin/sh
set -eu

container=${1:-royd}

command -v docker >/dev/null 2>&1 || {
  printf '%s\n' 'error: docker is required to collect a memory report' >&2
  exit 1
}
if ! docker inspect "$container" >/dev/null 2>&1; then
  printf 'error: container not found: %s\n' "$container" >&2
  exit 1
fi
if [ "$(docker inspect -f '{{.State.Running}}' "$container")" != true ]; then
  printf 'error: container is not running: %s\n' "$container" >&2
  exit 1
fi

printf 'royd memory report\n'
printf 'container: %s\n' "$container"
printf 'image: %s\n' "$(docker inspect -f '{{.Config.Image}}' "$container")"
printf 'memory limit: %s bytes\n' "$(docker inspect -f '{{.HostConfig.Memory}}' "$container")"
printf '\ncontainer usage\n'
docker stats --no-stream --format 'memory={{.MemUsage}} percentage={{.MemPerc}} pids={{.PIDs}}' "$container"
printf '\nAndroid memory profile\n'
for property in ro.config.low_ram ro.lmk.use_psi ro.lmk.use_minfree_levels; do
  value=$(docker exec "$container" getprop "$property" 2>/dev/null || true)
  printf '%s=%s\n' "$property" "${value:-<unset>}"
done
printf '\nAndroid memory summary\n'
docker exec "$container" dumpsys meminfo 2>/dev/null | sed -n '/Total RAM:/p;/Free RAM:/p;/Used RAM:/p;/Lost RAM:/p;/ZRAM:/p'
printf '\nLargest resident processes\n'
docker exec "$container" sh -c 'ps -A -o RSS,NAME | tail -n +2 | sort -nr | head -n 15' 2>/dev/null || true
