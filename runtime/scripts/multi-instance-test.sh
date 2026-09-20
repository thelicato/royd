#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
image=${1:-${ROYD_IMAGE:-royd:dev}}
timeout=${ROYD_BOOT_TIMEOUT:-180}
prefix=${ROYD_MULTI_PREFIX:-royd-multi-$$}
container_a=${prefix}-a
container_b=${prefix}-b
volume_a=${container_a}-data
volume_b=${container_b}-data

command -v docker >/dev/null 2>&1 || {
  printf '%s\n' 'error: docker is required for runtime validation' >&2
  exit 1
}

docker image inspect "$image" >/dev/null 2>&1 || {
  printf 'error: image not found: %s\n' "$image" >&2
  exit 1
}

cleanup() {
  docker rm -f "$container_a" "$container_b" >/dev/null 2>&1 || true
  docker volume rm "$volume_a" "$volume_b" >/dev/null 2>&1 || true
}
trap cleanup EXIT HUP INT TERM
cleanup

docker volume create "$volume_a" >/dev/null
docker volume create "$volume_b" >/dev/null
printf 'Starting two royd containers from %s\n' "$image"
docker run -d --privileged --name "$container_a" -v "$volume_a:/data" "$image" >/dev/null
docker run -d --privileged --name "$container_b" -v "$volume_b:/data" "$image" >/dev/null

"$script_dir/wait-for-boot.sh" "$container_a" "$timeout"
"$script_dir/wait-for-boot.sh" "$container_b" "$timeout"
"$script_dir/assert-runtime.sh" "$container_a"
"$script_dir/assert-runtime.sh" "$container_b"
printf '%s\n' 'Two-instance runtime smoke test passed'
printf '%s\n' 'Note: this confirms independent binderfs mounts are created, not cross-context Binder IPC isolation.'
