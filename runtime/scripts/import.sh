#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
# shellcheck disable=SC1091
. "$repo_root/android/baseline.env"
# shellcheck disable=SC1091
. "$repo_root/runtime/image.env"

arch=${1:-x86_64}
profile=${2:-${ROYD_ANDROID_PROFILE:-standard}}
requested_image=${3:-}
profile=$($repo_root/android/scripts/profile.sh "$profile")
canonical=$($script_dir/image-tag.sh "$arch" "$profile")
alias=$($script_dir/image-alias.sh "$arch" "$profile")
image=${requested_image:-$canonical}

case "$arch" in
  x86_64) platform=linux/amd64 ;;
  arm64) platform=linux/arm64 ;;
  *)
    printf 'error: unsupported architecture: %s; expected x86_64 or arm64\n' "$arch" >&2
    exit 1
    ;;
esac

archive="$repo_root/.work/runtime/royd-$arch-$profile.tar"
manifest="$repo_root/.work/runtime/royd-$arch-$profile.manifest"
command -v sha256sum >/dev/null 2>&1 || {
  printf '%s\n' 'error: sha256sum is required to verify the runtime archive' >&2
  exit 1
}
command -v docker >/dev/null 2>&1 || {
  printf '%s\n' 'error: docker is required to import the runtime image' >&2
  exit 1
}
[ -f "$archive" ] || {
  printf 'error: runtime archive not found at %s; package Android first\n' "$archive" >&2
  exit 1
}
[ -f "$manifest" ] || {
  printf 'error: runtime manifest not found at %s; package Android first\n' "$manifest" >&2
  exit 1
}

expected_sha=$(sed -n 's/^ARCHIVE_SHA256=//p' "$manifest")
actual_sha=$(sha256sum "$archive" | awk '{print $1}')
[ -n "$expected_sha" ] && [ "$expected_sha" = "$actual_sha" ] || {
  printf '%s\n' 'error: runtime archive does not match its manifest' >&2
  exit 1
}

version=${AOSP_TAG#android-}
version=$(printf '%s' "$version" | tr '_' '-')
printf 'Importing %s as %s\n' "$archive" "$image"
docker import \
  --platform "$platform" \
  -c 'ENTRYPOINT ["/init","androidboot.hardware=royd"]' \
  -c 'CMD ["androidboot.royd_width=540","androidboot.royd_height=960","androidboot.royd_dpi=240","androidboot.royd_fps=30"]' \
  -c 'LABEL org.opencontainers.image.title=royd' \
  -c 'LABEL org.opencontainers.image.description=Android runtime for OCI containers' \
  -c "LABEL org.opencontainers.image.version=$version" \
  -c "LABEL org.royd.image-format=$ROYD_IMAGE_FORMAT" \
  -c "LABEL org.royd.android-ref=$AOSP_TAG" \
  -c "LABEL org.royd.arch=$arch" \
  -c "LABEL org.royd.image-profile=$profile" \
  "$archive" \
  "$image" >/dev/null

if [ -z "$requested_image" ]; then
  docker tag "$image" "$alias"
  printf 'Development alias is ready: %s\n' "$alias"
fi
"$script_dir/image-inspect.sh" "$arch" "$profile" "$image"
printf 'Runtime image is ready: %s\n' "$image"
