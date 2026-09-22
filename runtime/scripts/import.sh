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
profile=${2:-${ROYD_ANDROID_PROFILE:-standard}}
requested_image=${3:-}
profile=$($repo_root/android/scripts/profile.sh "$profile")
hal_profile=${ROYD_HAL_PROFILE:-graphical}
hal_profile=$("$repo_root/android/scripts/hal-profile.sh" "$hal_profile")
graphics_backend=${ROYD_GRAPHICS_BACKEND:-software}
graphics_backend=$(ROYD_GRAPHICS_ARCH="$arch" "$repo_root/android/scripts/graphics-backend.sh" "$graphics_backend" "$arch")
profile_policy=$(ROYD_ANDROID_VERSION="$ANDROID_VERSION" "$repo_root/android/scripts/profile-policy.sh" "$profile")
profile_policy_sha256=$(ROYD_ANDROID_VERSION="$ANDROID_VERSION" "$repo_root/android/scripts/profile-packages.sh" "$profile" | sha256sum | awk '{print $1}')
graphics_suffix=
[ "$graphics_backend" = software ] || graphics_suffix="-$graphics_backend"
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

archive="$repo_root/.work/runtime/android-$ANDROID_VERSION/royd-$arch-$profile-$hal_profile$graphics_suffix.tar"
manifest="$repo_root/.work/runtime/android-$ANDROID_VERSION/royd-$arch-$profile-$hal_profile$graphics_suffix.manifest"
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
case "$hal_profile" in
  graphical) default_cmd='["royd.width=540","royd.height=960","royd.dpi=240","royd.fps=30"]' ;;
  headless) default_cmd='["royd.width=64","royd.height=64","royd.dpi=72","royd.fps=5"]' ;;
esac
printf 'Importing %s as %s\n' "$archive" "$image"
docker import \
  --platform "$platform" \
  -c 'ENTRYPOINT ["/royd-entrypoint"]' \
  -c "CMD $default_cmd" \
  -c 'EXPOSE 5555/tcp' \
  -c 'HEALTHCHECK --interval=10s --timeout=5s --start-period=45s --retries=6 CMD ["/vendor/bin/royd-health"]' \
  -c 'LABEL org.opencontainers.image.title=royd' \
  -c 'LABEL org.opencontainers.image.description="Android runtime for OCI containers"' \
  -c "LABEL org.opencontainers.image.version=$version" \
  -c "LABEL org.royd.image-format=$ROYD_IMAGE_FORMAT" \
  -c "LABEL org.royd.android-version=$ANDROID_VERSION" \
  -c "LABEL org.royd.android-ref=$AOSP_TAG" \
  -c "LABEL org.royd.arch=$arch" \
  -c "LABEL org.royd.image-profile=$profile" \
  -c "LABEL org.royd.profile-policy=$profile_policy" \
  -c "LABEL org.royd.profile-policy-sha256=$profile_policy_sha256" \
  -c "LABEL org.royd.hal-profile=$hal_profile" \
  -c "LABEL org.royd.graphics-backend=$graphics_backend" \
  "$archive" \
  "$image" >/dev/null

if [ -z "$requested_image" ]; then
  docker tag "$image" "$alias"
  printf 'Development alias is ready: %s\n' "$alias"
fi
"$script_dir/image-inspect.sh" "$arch" "$profile" "$image"
printf 'Runtime image is ready: %s\n' "$image"
