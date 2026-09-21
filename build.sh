#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
cd "$repo_root"

usage() {
  cat <<'EOF_USAGE'
Usage: ./build.sh [options]

Build and import a royd Android OCI image from the current checkout.

Build selection:
  --android VERSION           Android version. Default: ROYD_ANDROID_VERSION or 15
  --arch ARCH                 x86_64 or arm64. Default: ROYD_ARCH or x86_64
  --profile PROFILE           Android image profile. Default: ROYD_ANDROID_PROFILE or standard
  --hal-profile PROFILE       graphical or headless. Default: ROYD_HAL_PROFILE or graphical
  --graphics BACKEND          Graphics backend. Default: ROYD_GRAPHICS_BACKEND or software

Build control:
  --jobs N                    Android compile jobs. Default: JOBS or host CPU count
  --sync-jobs N               AOSP sync jobs. Default: SYNC_JOBS or 1
  --sync-attempts N           Whole-sync attempts. Default: SYNC_ATTEMPTS or 6
  --sync-retry-delay SECONDS  Delay between sync attempts. Default: SYNC_RETRY_DELAY or 60
  --skip-sync                 Reuse an existing synced source tree
  --clean                     Remove the selected Android out directory before building
  --incremental               Reuse the selected Android out directory
  -h, --help                  Show this help

A clean build is the default. AOSP source and partial sync state are preserved under .work.
The wrapper validates selections using repository-owned scripts and does not patch AOSP,
rewrite royd source, alter VINTF enforcement, or generate manifests.

Example:
  ./build.sh --android 15 --arch x86_64 --sync-jobs 1 --jobs "$(nproc)"
EOF_USAGE
}

# shellcheck disable=SC1091
. "$repo_root/android/baseline.env"

android_version=${ROYD_ANDROID_VERSION:-$ROYD_DEFAULT_ANDROID_VERSION}
arch=${ROYD_ARCH:-x86_64}
profile=${ROYD_ANDROID_PROFILE:-standard}
hal_profile=${ROYD_HAL_PROFILE:-graphical}
graphics_backend=${ROYD_GRAPHICS_BACKEND:-software}
build_jobs=${JOBS:-}
sync_jobs=${SYNC_JOBS:-1}
sync_attempts=${SYNC_ATTEMPTS:-6}
sync_retry_delay=${SYNC_RETRY_DELAY:-60}
skip_sync=${SKIP_SYNC:-0}
clean_build=${ROYD_CLEAN_BUILD:-1}

while (($#)); do
  case "$1" in
    --android)
      (($# >= 2)) || { printf '%s\n' 'error: --android requires a value' >&2; exit 2; }
      android_version=$2
      shift 2
      ;;
    --arch)
      (($# >= 2)) || { printf '%s\n' 'error: --arch requires a value' >&2; exit 2; }
      arch=$2
      shift 2
      ;;
    --profile)
      (($# >= 2)) || { printf '%s\n' 'error: --profile requires a value' >&2; exit 2; }
      profile=$2
      shift 2
      ;;
    --hal-profile)
      (($# >= 2)) || { printf '%s\n' 'error: --hal-profile requires a value' >&2; exit 2; }
      hal_profile=$2
      shift 2
      ;;
    --graphics)
      (($# >= 2)) || { printf '%s\n' 'error: --graphics requires a value' >&2; exit 2; }
      graphics_backend=$2
      shift 2
      ;;
    --jobs)
      (($# >= 2)) || { printf '%s\n' 'error: --jobs requires a value' >&2; exit 2; }
      build_jobs=$2
      shift 2
      ;;
    --sync-jobs)
      (($# >= 2)) || { printf '%s\n' 'error: --sync-jobs requires a value' >&2; exit 2; }
      sync_jobs=$2
      shift 2
      ;;
    --sync-attempts)
      (($# >= 2)) || { printf '%s\n' 'error: --sync-attempts requires a value' >&2; exit 2; }
      sync_attempts=$2
      shift 2
      ;;
    --sync-retry-delay)
      (($# >= 2)) || { printf '%s\n' 'error: --sync-retry-delay requires a value' >&2; exit 2; }
      sync_retry_delay=$2
      shift 2
      ;;
    --skip-sync)
      skip_sync=1
      shift
      ;;
    --clean)
      clean_build=1
      shift
      ;;
    --incremental)
      clean_build=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'error: unknown option: %s\n\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

for command_name in docker sha256sum sleep tee; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf 'error: required host command not found: %s\n' "$command_name" >&2
    exit 1
  }
done

if [ -z "$build_jobs" ]; then
  if command -v nproc >/dev/null 2>&1; then
    build_jobs=$(nproc)
  else
    build_jobs=$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '4')
  fi
fi

positive_integer() {
  local name=$1
  local value=$2
  case "$value" in
    ''|*[!0-9]*|0)
      printf 'error: %s must be a positive integer, got: %s\n' "$name" "$value" >&2
      exit 2
      ;;
  esac
}

positive_integer JOBS "$build_jobs"
positive_integer SYNC_JOBS "$sync_jobs"
positive_integer SYNC_ATTEMPTS "$sync_attempts"
case "$sync_retry_delay" in
  ''|*[!0-9]*)
    printf 'error: SYNC_RETRY_DELAY must be a non-negative integer, got: %s\n' "$sync_retry_delay" >&2
    exit 2
    ;;
esac
case "$skip_sync" in
  0|1) ;;
  *) printf 'error: SKIP_SYNC must be 0 or 1, got: %s\n' "$skip_sync" >&2; exit 2 ;;
esac
case "$clean_build" in
  0|1) ;;
  *) printf 'error: ROYD_CLEAN_BUILD must be 0 or 1, got: %s\n' "$clean_build" >&2; exit 2 ;;
esac

version_env="$repo_root/android/versions/$android_version.env"
if [ ! -f "$version_env" ]; then
  versions=$("$repo_root/android/scripts/version-list.sh" | tr '\n' ' ' | sed 's/ $//')
  printf 'error: unsupported Android version: %s; expected one of %s\n' "$android_version" "$versions" >&2
  exit 2
fi

profile=$(ROYD_ANDROID_VERSION="$android_version" "$repo_root/android/scripts/profile.sh" "$profile")
hal_profile=$("$repo_root/android/scripts/hal-profile.sh" "$hal_profile")
graphics_backend=$(
  ROYD_ANDROID_VERSION="$android_version" \
  ROYD_GRAPHICS_ARCH="$arch" \
    "$repo_root/android/scripts/graphics-backend.sh" "$graphics_backend" "$arch"
)
ROYD_ANDROID_VERSION="$android_version" "$repo_root/android/scripts/lunch-target.sh" "$arch" >/dev/null

docker info >/dev/null 2>&1 || {
  printf '%s\n' 'error: Docker is installed but the daemon is unavailable or this user cannot access it' >&2
  printf '%s\n' 'Verify that `docker info` succeeds, then rerun this command.' >&2
  exit 1
}

config_slug="android${android_version}-${arch}-${profile}-${hal_profile}-${graphics_backend}"
log_dir="$repo_root/.work/logs"
mkdir -p "$log_dir"
log_file="$log_dir/$config_slug.log"
touch "$log_file"
exec > >(tee -a "$log_file") 2>&1

builder="$repo_root/android/scripts/builder.sh"
sync_script=android/scripts/sync.sh
config_script=android/scripts/config-check.sh
build_script=android/scripts/build.sh
package_script=android/scripts/package.sh
import_script="$repo_root/runtime/scripts/import.sh"
image_tag_script="$repo_root/runtime/scripts/image-tag.sh"
image_alias_script="$repo_root/runtime/scripts/image-alias.sh"

run_builder() {
  local jobs=$1
  local clean=$2
  shift 2
  env \
    JOBS="$jobs" \
    ROYD_CLEAN_BUILD="$clean" \
    ROYD_ANDROID_VERSION="$android_version" \
    ROYD_ANDROID_PROFILE="$profile" \
    ROYD_HAL_PROFILE="$hal_profile" \
    ROYD_GRAPHICS_BACKEND="$graphics_backend" \
    ROYD_BUILDER_TTY="${ROYD_BUILDER_TTY:-never}" \
    "$builder" "$@"
}

printf 'royd build root: %s\n' "$repo_root"
printf 'Android version: %s\n' "$android_version"
printf 'Architecture: %s\n' "$arch"
printf 'Image profile: %s\n' "$profile"
printf 'HAL profile: %s\n' "$hal_profile"
printf 'Graphics backend: %s\n' "$graphics_backend"
printf 'Clean build: %s\n' "$clean_build"
printf 'Build jobs: %s\n' "$build_jobs"
printf 'Sync jobs: %s\n' "$sync_jobs"
printf 'Sync attempts: %s\n' "$sync_attempts"
printf 'Skip sync: %s\n' "$skip_sync"
printf 'Build log: %s\n' "$log_file"

source_dir="$repo_root/.work/android-src-$android_version"
if [ "$skip_sync" = 1 ]; then
  [ -d "$source_dir/.repo" ] || {
    printf 'error: --skip-sync requested but no existing Android %s checkout was found at %s\n' "$android_version" "$source_dir" >&2
    exit 1
  }
  printf '\nReusing existing Android %s source checkout.\n' "$android_version"
else
  sync_ok=0
  for ((attempt=1; attempt<=sync_attempts; attempt++)); do
    printf '\nSynchronising Android %s, attempt %s/%s with %s job(s).\n' \
      "$android_version" "$attempt" "$sync_attempts" "$sync_jobs"
    if run_builder "$sync_jobs" 0 "$sync_script"; then
      sync_ok=1
      break
    fi
    if ((attempt < sync_attempts)); then
      printf 'Sync failed. Partial checkout is preserved; retrying in %s second(s).\n' "$sync_retry_delay"
      sleep "$sync_retry_delay"
    fi
  done
  [ "$sync_ok" -eq 1 ] || {
    printf '%s\n' 'error: AOSP synchronisation did not complete; the partial checkout has been preserved' >&2
    exit 1
  }
fi

printf '\nChecking resolved Android configuration for %s.\n' "$arch"
run_builder "$build_jobs" 0 "$config_script" "$arch"

printf '\nBuilding Android %s for %s.\n' "$android_version" "$arch"
run_builder "$build_jobs" "$clean_build" "$build_script" "$arch" "$profile"

printf '\nPackaging Android %s for %s.\n' "$android_version" "$arch"
run_builder "$build_jobs" 0 "$package_script" "$arch" "$profile"

printf '\nImporting OCI image.\n'
env \
  ROYD_ANDROID_VERSION="$android_version" \
  ROYD_ANDROID_PROFILE="$profile" \
  ROYD_HAL_PROFILE="$hal_profile" \
  ROYD_GRAPHICS_BACKEND="$graphics_backend" \
  "$import_script" "$arch" "$profile"

image=$(
  env \
    ROYD_ANDROID_VERSION="$android_version" \
    ROYD_ANDROID_PROFILE="$profile" \
    ROYD_HAL_PROFILE="$hal_profile" \
    ROYD_GRAPHICS_BACKEND="$graphics_backend" \
    "$image_tag_script" "$arch" "$profile"
)
alias=$(
  env \
    ROYD_ANDROID_VERSION="$android_version" \
    ROYD_ANDROID_PROFILE="$profile" \
    ROYD_HAL_PROFILE="$hal_profile" \
    ROYD_GRAPHICS_BACKEND="$graphics_backend" \
    "$image_alias_script" "$arch" "$profile"
)
graphics_suffix=
[ "$graphics_backend" = software ] || graphics_suffix="-$graphics_backend"
runtime_dir="$repo_root/.work/runtime/android-$android_version"
archive="$runtime_dir/royd-$arch-$profile-$hal_profile$graphics_suffix.tar"
manifest="$runtime_dir/royd-$arch-$profile-$hal_profile$graphics_suffix.manifest"

printf '\nBuild complete.\n'
printf 'Docker image: %s\n' "$image"
printf 'Development alias: %s\n' "$alias"
printf 'Root filesystem archive: %s\n' "$archive"
printf 'Manifest: %s\n' "$manifest"
printf 'Build log: %s\n' "$log_file"
printf '\nArtefact checksums:\n'
sha256sum "$archive" "$manifest"
printf '\nDocker image summary:\n'
docker image inspect "$image" --format 'ID={{.Id}} Size={{.Size}} Created={{.Created}}'
