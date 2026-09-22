#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
default_image=$("$script_dir/default-image.sh" standard x86_64)
image=${1:-${ROYD_IMAGE:-$default_image}}
container=${ROYD_SMOKE_CONTAINER:-royd-smoke-$$}
volume=${container}-data
timeout=${ROYD_BOOT_TIMEOUT:-180}
profile=${ROYD_PROFILE:-$("$script_dir/default-runtime-profile.sh")}

command -v docker >/dev/null 2>&1 || {
  printf '%s\n' 'error: docker is required for runtime validation' >&2
  exit 1
}

docker image inspect "$image" >/dev/null 2>&1 || {
  printf 'error: image not found: %s\n' "$image" >&2
  exit 1
}

profile_args=$("$script_dir/profile.sh" "$profile")
security_mode=${ROYD_SECURITY_MODE:-privileged}
security_args=$("$script_dir/security-args.sh" "$security_mode")
container_args=$("$script_dir/container-args.sh")
runtime_arch=${ROYD_ARCH:-${ROYD_QUALIFY_ARCH:-x86_64}}
gpu_args=$(ROYD_GRAPHICS_ARCH="$runtime_arch" "$script_dir/gpu-args.sh" "${ROYD_GRAPHICS_BACKEND:-software}" "$runtime_arch")

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker volume rm "$volume" >/dev/null 2>&1 || true
}
trap cleanup EXIT HUP INT TERM
cleanup

docker volume create "$volume" >/dev/null
printf 'Starting runtime smoke test with %s using profile %s and security mode %s\n' "$image" "$profile" "$security_mode"
# Word splitting is intentional because profile.sh and security-args.sh emit trusted arguments.
# shellcheck disable=SC2086
docker run -d $security_args $gpu_args $container_args \
  --name "$container" \
  -v "$volume:/data" \
  "$image" $profile_args >/dev/null

"$script_dir/assert-security.sh" "$container" "$security_mode"
"$script_dir/wait-for-boot.sh" "$container" "$timeout"
"$script_dir/assert-runtime.sh" "$container"
printf '%s\n' 'Single-instance runtime smoke test passed'
