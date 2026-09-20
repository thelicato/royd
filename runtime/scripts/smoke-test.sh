#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
image=${1:-${ROYD_IMAGE:-royd:dev}}
container=${ROYD_SMOKE_CONTAINER:-royd-smoke-$$}
volume=${container}-data
timeout=${ROYD_BOOT_TIMEOUT:-180}

command -v docker >/dev/null 2>&1 || {
  printf '%s\n' 'error: docker is required for runtime validation' >&2
  exit 1
}

docker image inspect "$image" >/dev/null 2>&1 || {
  printf 'error: image not found: %s\n' "$image" >&2
  exit 1
}

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker volume rm "$volume" >/dev/null 2>&1 || true
}
trap cleanup EXIT HUP INT TERM
cleanup

docker volume create "$volume" >/dev/null
printf 'Starting runtime smoke test with %s\n' "$image"
docker run -d --privileged \
  --name "$container" \
  -v "$volume:/data" \
  "$image" >/dev/null

"$script_dir/wait-for-boot.sh" "$container" "$timeout"
"$script_dir/assert-runtime.sh" "$container"
printf '%s\n' 'Single-instance runtime smoke test passed'
