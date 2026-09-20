#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
image=${1:?usage: memory-provenance.sh IMAGE [RUNTIME_PROFILE]}
profile=${2:-${ROYD_PROFILE:-$("$script_dir/default-runtime-profile.sh")}}

command -v docker >/dev/null 2>&1 || {
  printf '%s\n' 'error: docker is required to inspect benchmark provenance' >&2
  exit 1
}

docker image inspect "$image" >/dev/null 2>&1 || {
  printf 'error: image not found: %s\n' "$image" >&2
  exit 1
}

image_label() {
  docker image inspect --format "{{index .Config.Labels \"$1\"}}" "$image" 2>/dev/null || true
}

image_id=$(docker image inspect --format '{{.Id}}' "$image" 2>/dev/null || true)
android_version=$(image_label org.royd.android-version)
aosp_ref=$(image_label org.royd.android-ref)
image_profile=$(image_label org.royd.image-profile)
profile_policy=$(image_label org.royd.profile-policy)
profile_policy_sha256=$(image_label org.royd.profile-policy-sha256)
hal_profile=$(image_label org.royd.hal-profile)
graphics_backend=$(image_label org.royd.graphics-backend)
for item in image_id android_version aosp_ref image_profile profile_policy profile_policy_sha256 hal_profile graphics_backend; do
  eval "value=\${$item:-}"
  [ -n "$value" ] && [ "$value" != '<no value>' ] || {
    printf 'error: image %s is missing benchmark provenance metadata: %s\n' "$image" "$item" >&2
    exit 1
  }
done

profile_file="$script_dir/../profiles/$profile.env"
[ -f "$profile_file" ] || {
  printf 'error: unknown runtime profile: %s\n' "$profile" >&2
  exit 2
}
# shellcheck disable=SC1090
. "$profile_file"

printf -- '- image: `%s`\n' "$image"
printf -- '- image ID: `%s`\n' "$image_id"
printf -- '- Android version: `%s`\n' "$android_version"
printf -- '- AOSP ref: `%s`\n' "$aosp_ref"
printf -- '- Android image profile: `%s`\n' "$image_profile"
printf -- '- image profile policy: `%s`\n' "$profile_policy"
printf -- '- image profile policy SHA-256: `%s`\n' "$profile_policy_sha256"
printf -- '- HAL profile: `%s`\n' "$hal_profile"
printf -- '- graphics backend: `%s`\n' "$graphics_backend"
printf -- '- runtime display profile: `%s` (%sx%s, %s dpi, %s fps)\n' "$profile" "$ROYD_WIDTH" "$ROYD_HEIGHT" "$ROYD_DPI" "$ROYD_FPS"
