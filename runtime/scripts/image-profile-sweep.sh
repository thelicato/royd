#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
profiles=${ROYD_ANDROID_PROFILES:-'standard minimal'}
limits=${ROYD_MEMORY_LIMITS:-'512m 640m 768m 896m 1024m'}
runtime_profile=${ROYD_PROFILE:-compact}
output=${ROYD_IMAGE_PROFILE_SWEEP_OUTPUT:--}
workdir=$(mktemp -d)

cleanup() {
  rm -rf "$workdir"
}
trap cleanup EXIT HUP INT TERM

command -v docker >/dev/null 2>&1 || {
  printf '%s\n' 'error: docker is required for an image profile comparison' >&2
  exit 1
}

image_for_profile() {
  case "$1" in
    standard) default=$("$script_dir/default-image.sh" standard x86_64); printf '%s\n' "${ROYD_STANDARD_IMAGE:-$default}" ;;
    minimal) default=$("$script_dir/default-image.sh" minimal x86_64); printf '%s\n' "${ROYD_MINIMAL_IMAGE:-$default}" ;;
    *) "$script_dir/default-image.sh" "$1" x86_64 ;;
  esac
}

: >"$workdir/sections.tsv"
for image_profile in $profiles; do
  "$repo_root/android/scripts/profile.sh" "$image_profile" >/dev/null
  image=$(image_for_profile "$image_profile")
  docker image inspect "$image" >/dev/null 2>&1 || {
    printf 'error: image not found for profile %s: %s\n' "$image_profile" "$image" >&2
    exit 1
  }
  image_size=$(docker image inspect --format '{{.Size}}' "$image" 2>/dev/null || true)
  [ -n "$image_size" ] || image_size=unavailable
  report="$workdir/$image_profile.md"
  printf 'Benchmarking Android image profile %s using %s\n' "$image_profile" "$image" >&2
  ROYD_IMAGE="$image" \
  ROYD_PROFILE="$runtime_profile" \
  ROYD_MEMORY_LIMITS="$limits" \
  ROYD_MEMORY_SWEEP_OUTPUT="$report" \
    "$script_dir/memory-sweep.sh" "$image"
  printf '%s\t%s\t%s\t%s\n' "$image_profile" "$image" "$image_size" "$report" >>"$workdir/sections.tsv"
done

combined="$workdir/report.md"
{
  printf '# royd Android image profile comparison\n\n'
  printf 'This report compares independently built Android image profiles under the same runtime display profile and candidate memory limits. Results apply only to the tested images and host.\n\n'
  printf -- '- Android image profiles: `%s`\n' "$profiles"
  printf -- '- runtime display profile: `%s`\n' "$runtime_profile"
  printf -- '- candidate memory limits: `%s`\n\n' "$limits"
  printf '| Android profile | Image | Docker image size (bytes) |\n'
  printf '| --- | --- | ---: |\n'
  while IFS="$(printf '\t')" read -r image_profile image image_size report; do
    printf '| `%s` | `%s` | %s |\n' "$image_profile" "$image" "$image_size"
  done <"$workdir/sections.tsv"
  printf '\n'
  while IFS="$(printf '\t')" read -r image_profile image image_size report; do
    printf '## `%s`\n\n' "$image_profile"
    sed -e '1d' -e 's/^## /### /' "$report"
    printf '\n'
  done <"$workdir/sections.tsv"
  printf '## Interpretation\n\n'
  printf 'A lower passing memory limit is useful evidence, but it is not enough on its own to select a default image profile. Compare boot reliability, installed functionality, resident memory, image size, and workload behaviour before changing defaults.\n'
} >"$combined"

if [ "$output" = '-' ]; then
  cat "$combined"
else
  mkdir -p "$(dirname -- "$output")"
  cp "$combined" "$output"
  printf 'Wrote image profile comparison to %s\n' "$output"
fi
