#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1091
. "$script_dir/binder-identity-lib.sh"
default_image=$("$script_dir/default-image.sh" standard x86_64)
image=${1:-${ROYD_IMAGE:-$default_image}}
timeout=${ROYD_BOOT_TIMEOUT:-180}
hal_profile=${ROYD_HAL_PROFILE:-graphical}
profile=${ROYD_PROFILE:-$("$script_dir/default-runtime-profile.sh")}
security_mode=${ROYD_SECURITY_MODE:-privileged}
prefix=${ROYD_BINDER_PREFIX:-royd-binder-$$}
container_a=${prefix}-a
container_b=${prefix}-b
volume_a=${container_a}-data
volume_b=${container_b}-data

profile_args=$("$script_dir/profile.sh" "$profile")
security_args=$("$script_dir/security-args.sh" "$security_mode")
runtime_arch=${ROYD_ARCH:-${ROYD_QUALIFY_ARCH:-x86_64}}
gpu_args=$(ROYD_GRAPHICS_ARCH="$runtime_arch" "$script_dir/gpu-args.sh" "${ROYD_GRAPHICS_BACKEND:-software}" "$runtime_arch")

cleanup() {
  docker rm -f "$container_a" "$container_b" >/dev/null 2>&1 || true
  docker volume rm "$volume_a" "$volume_b" >/dev/null 2>&1 || true
}
trap cleanup EXIT HUP INT TERM
cleanup

docker image inspect "$image" >/dev/null 2>&1 || {
  printf 'error: image not found: %s\n' "$image" >&2
  exit 1
}
docker volume create "$volume_a" >/dev/null
docker volume create "$volume_b" >/dev/null
printf 'Starting Binder isolation test with %s using HAL profile %s\n' "$image" "$hal_profile"
# Word splitting is intentional because these helpers emit trusted Docker and Android arguments.
# shellcheck disable=SC2086
docker run -d $security_args $gpu_args --name "$container_a" -v "$volume_a:/data" "$image" $profile_args >/dev/null
# shellcheck disable=SC2086
docker run -d $security_args $gpu_args --name "$container_b" -v "$volume_b:/data" "$image" $profile_args >/dev/null

"$script_dir/wait-for-boot.sh" "$container_a" "$timeout"
"$script_dir/wait-for-boot.sh" "$container_b" "$timeout"
"$script_dir/assert-runtime.sh" "$container_a"
"$script_dir/assert-runtime.sh" "$container_b"

identity_a=$(docker exec "$container_a" /vendor/bin/royd-binder-info)
identity_b=$(docker exec "$container_b" /vendor/bin/royd-binder-info)

binder_identities_isolated "$identity_a" "$identity_b" || {
  printf '%s\n' 'error: Binder device identities are missing or shared between the two containers' >&2
  printf 'container A:\n%s\ncontainer B:\n%s\n' "$identity_a" "$identity_b" >&2
  exit 1
}

printf '%s\n' 'Binder isolation test passed: private binderfs devices have distinct kernel device identities'
