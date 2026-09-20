#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
arch=${1:-x86_64}
profile=${2:-${ROYD_ANDROID_PROFILE:-standard}}
image=${3:-}
profile=$($repo_root/android/scripts/profile.sh "$profile")

case "$arch" in
  x86_64)
    platform=linux/amd64
    ;;
  arm64)
    platform=linux/arm64
    ;;
  *)
    printf 'error: unsupported architecture: %s; expected x86_64 or arm64\n' "$arch" >&2
    exit 1
    ;;
esac

if [ -z "$image" ]; then
  if [ "$profile" = standard ]; then
    image=royd:dev
  else
    image="royd:dev-$profile"
  fi
fi
archive="$repo_root/.work/runtime/royd-$arch-$profile.tar"
command -v docker >/dev/null 2>&1 || {
  printf '%s\n' 'error: docker is required to import the runtime image' >&2
  exit 1
}
[ -f "$archive" ] || {
  printf 'error: runtime archive not found at %s; package Android first\n' "$archive" >&2
  exit 1
}

printf 'Importing %s as %s\n' "$archive" "$image"
docker import \
  --platform "$platform" \
  -c 'ENTRYPOINT ["/init","androidboot.hardware=redroid","androidboot.use_memfd=true"]' \
  -c 'CMD ["androidboot.redroid_width=540","androidboot.redroid_height=960","androidboot.redroid_dpi=240","androidboot.redroid_fps=30"]' \
  -c "LABEL org.royd.image-profile=$profile" \
  "$archive" \
  "$image" >/dev/null
printf 'Runtime image is ready: %s\n' "$image"
