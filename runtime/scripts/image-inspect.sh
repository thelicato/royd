#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
# shellcheck disable=SC1091
. "$repo_root/android/baseline.env"
android_version=${ROYD_ANDROID_VERSION:-$ROYD_DEFAULT_ANDROID_VERSION}
version_env="$repo_root/android/versions/$android_version.env"
[ -f "$version_env" ] || {
  versions=$("$repo_root/android/scripts/version-list.sh" | tr '\n' ' ' | sed 's/ $//')
  printf 'error: unsupported Android version: %s; expected one of %s\n' "$android_version" "$versions" >&2
  exit 1
}
# shellcheck disable=SC1090
. "$version_env"
# shellcheck disable=SC1091
. "$repo_root/runtime/image.env"

arch=${1:-x86_64}
profile=${2:-standard}
profile=$($repo_root/android/scripts/profile.sh "$profile")
hal_profile=${ROYD_HAL_PROFILE:-graphical}
hal_profile=$("$repo_root/android/scripts/hal-profile.sh" "$hal_profile")
graphics_backend=${ROYD_GRAPHICS_BACKEND:-software}
graphics_backend=$(ROYD_GRAPHICS_ARCH="$arch" "$repo_root/android/scripts/graphics-backend.sh" "$graphics_backend" "$arch")
image=${3:-$($script_dir/image-tag.sh "$arch" "$profile")}

case "$arch" in
  x86_64) docker_arch=amd64 ;;
  arm64) docker_arch=arm64 ;;
  *)
    printf 'error: unsupported architecture: %s; expected x86_64 or arm64\n' "$arch" >&2
    exit 1
    ;;
esac

command -v docker >/dev/null 2>&1 || {
  printf '%s\n' 'error: docker is required to inspect the runtime image' >&2
  exit 1
}

equal() {
  name=$1
  actual=$2
  expected=$3
  [ "$actual" = "$expected" ] || {
    printf 'error: %s mismatch: expected %s, got %s\n' "$name" "$expected" "$actual" >&2
    exit 1
  }
}

label() {
  docker image inspect --format "{{index .Config.Labels \"$1\"}}" "$image"
}

actual_arch=$(docker image inspect --format '{{.Architecture}}' "$image")
equal architecture "$actual_arch" "$docker_arch"
equal image-format "$(label org.royd.image-format)" "$ROYD_IMAGE_FORMAT"
equal android-version "$(label org.royd.android-version)" "$ANDROID_VERSION"
equal android-ref "$(label org.royd.android-ref)" "$AOSP_TAG"
equal image-profile "$(label org.royd.image-profile)" "$profile"
equal hal-profile "$(label org.royd.hal-profile)" "$hal_profile"
equal graphics-backend "$(label org.royd.graphics-backend)" "$graphics_backend"
equal royd-arch "$(label org.royd.arch)" "$arch"
equal title "$(label org.opencontainers.image.title)" royd

entrypoint=$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")
equal entrypoint "$entrypoint" '["/init","androidboot.hardware=royd"]'

healthcheck=$(docker image inspect --format '{{json .Config.Healthcheck.Test}}' "$image")
equal healthcheck "$healthcheck" '["CMD","/vendor/bin/royd-health"]'
exposed=$(docker image inspect --format '{{json .Config.ExposedPorts}}' "$image")
printf '%s\n' "$exposed" | grep -Fq '5555/tcp' || {
  printf '%s\n' 'error: image does not expose ADB port 5555/tcp' >&2
  exit 1
}

container_id=$(docker create --entrypoint /system/bin/cat "$image" /royd-release)
cleanup() {
  docker rm -f "$container_id" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM
release=$(docker cp "$container_id:/royd-release" - 2>/dev/null | tar -xOf -)
printf '%s\n' "$release" | grep -Fqx "ROYD_IMAGE_FORMAT=$ROYD_IMAGE_FORMAT"
printf '%s\n' "$release" | grep -Fqx "ROYD_ANDROID_VERSION=$ANDROID_VERSION"
printf '%s\n' "$release" | grep -Fqx "ROYD_AOSP_TAG=$AOSP_TAG"
printf '%s\n' "$release" | grep -Fqx "ROYD_ARCH=$arch"
printf '%s\n' "$release" | grep -Fqx "ROYD_IMAGE_PROFILE=$profile"
printf '%s\n' "$release" | grep -Fqx "ROYD_HAL_PROFILE=$hal_profile"
printf '%s\n' "$release" | grep -Fqx "ROYD_GRAPHICS_BACKEND=$graphics_backend"

printf 'Image contract passed: %s\n' "$image"
