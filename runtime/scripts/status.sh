#!/bin/sh
set -eu
container=${1:-${ROYD_CONTAINER:-royd}}
command -v docker >/dev/null 2>&1 || {
  printf '%s\n' 'error: docker is required' >&2
  exit 1
}
docker inspect "$container" >/dev/null 2>&1 || {
  printf 'error: container not found: %s\n' "$container" >&2
  exit 1
}
state=$(docker inspect --format '{{.State.Status}}' "$container")
health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container")
adb_port=$(docker port "$container" 5555/tcp 2>/dev/null | head -n 1 || true)
printf 'Container: %s\n' "$container"
printf 'State: %s\n' "$state"
printf 'Health: %s\n' "$health"
printf 'ADB: %s\n' "${adb_port:-not published}"
