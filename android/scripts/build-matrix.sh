#!/bin/sh
set -u

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
android_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
repo_root=$(CDPATH= cd -- "$android_dir/.." && pwd)
# shellcheck disable=SC1091
. "$android_dir/baseline.env"
# shellcheck disable=SC1091
. "$script_dir/build-result-lib.sh"

versions=${ROYD_BUILD_VERSIONS:-$("$script_dir/version-list.sh")}
arches=${ROYD_BUILD_ARCHES:-"x86_64 arm64"}
profile=${ROYD_ANDROID_PROFILE:-standard}
profile=$("$script_dir/profile.sh" "$profile")
hal_profile=${ROYD_HAL_PROFILE:-graphical}
hal_profile=$("$script_dir/hal-profile.sh" "$hal_profile")
graphics_backend_request=${ROYD_GRAPHICS_BACKEND:-software}
stages=${ROYD_BUILD_STAGES:-"config build package"}
sync_missing=${ROYD_BUILD_SYNC:-0}
resume=${ROYD_BUILD_RESUME:-1}
continue_on_error=${ROYD_BUILD_CONTINUE_ON_ERROR:-1}
clean_build=${ROYD_BUILD_CLEAN:-1}
work_root=${ROYD_WORK_DIR:-$repo_root/.work}
export ROYD_WORK_DIR="$work_root"
results_dir=${ROYD_BUILD_RESULTS_DIR:-$work_root/build-results}
report=${ROYD_BUILD_REPORT_OUTPUT:-$results_dir/build-matrix.md}
builder=${ROYD_BUILD_BUILDER:-$script_dir/builder.sh}
status=0

case "$sync_missing:$resume:$continue_on_error:$clean_build" in
  *[!01:]*)
    printf '%s\n' 'error: ROYD_BUILD_SYNC, ROYD_BUILD_RESUME, ROYD_BUILD_CONTINUE_ON_ERROR and ROYD_BUILD_CLEAN must be 0 or 1' >&2
    exit 1
    ;;
esac

has_stage() {
  wanted=$1
  for stage in $stages; do
    [ "$stage" = "$wanted" ] && return 0
  done
  return 1
}

validate_stages() {
  for stage in $stages; do
    case "$stage" in
      config|build|package) ;;
      *)
        printf 'error: unsupported build stage: %s; expected config, build or package\n' "$stage" >&2
        exit 1
        ;;
    esac
  done
}

validate_arches() {
  for arch in $arches; do
    case "$arch" in
      x86_64|arm64) ;;
      *)
        printf 'error: unsupported architecture: %s; expected x86_64 or arm64\n' "$arch" >&2
        exit 1
        ;;
    esac
  done
}

validate_versions() {
  for version in $versions; do
    [ -f "$android_dir/versions/$version.env" ] || {
      printf 'error: unsupported Android version in ROYD_BUILD_VERSIONS: %s\n' "$version" >&2
      exit 1
    }
  done
}

record_result() {
  result_file=$1
  result_status=$2
  config_status=$3
  build_status=$4
  package_status=$5
  started=$6
  finished=$7
  manifest_sha=$8
  archive_sha=$9
  # shellcheck disable=SC1090
  . "$android_dir/versions/$current_version.env"
  profile_policy=$(ROYD_ANDROID_VERSION="$current_version" "$script_dir/profile-policy.sh" "$profile")
  profile_policy_sha256=$(ROYD_ANDROID_VERSION="$current_version" "$script_dir/profile-packages.sh" "$profile" | sha256sum | awk '{print $1}')
  result_write "$result_file" \
    "RESULT_FORMAT=2" \
    "ANDROID_VERSION=$ANDROID_VERSION" \
    "AOSP_TAG=$AOSP_TAG" \
    "ARCH=$current_arch" \
    "IMAGE_PROFILE=$profile" \
    "PROFILE_POLICY=$profile_policy" \
    "PROFILE_POLICY_SHA256=$profile_policy_sha256" \
    "HAL_PROFILE=$hal_profile" \
    "GRAPHICS_BACKEND=$current_graphics_backend" \
    "CLEAN_BUILD=$clean_build" \
    "STAGES=$stages" \
    "SYNC_STATUS=$sync_status" \
    "CONFIG_STATUS=$config_status" \
    "BUILD_STATUS=$build_status" \
    "PACKAGE_STATUS=$package_status" \
    "RESULT_STATUS=$result_status" \
    "AOSP_MANIFEST_SHA256=$manifest_sha" \
    "ARCHIVE_SHA256=$archive_sha" \
    "STARTED_AT=$started" \
    "FINISHED_AT=$finished"
}

run_builder() {
  ROYD_ANDROID_VERSION=$current_version \
  ROYD_ANDROID_PROFILE=$profile \
  ROYD_HAL_PROFILE=$hal_profile \
  ROYD_GRAPHICS_BACKEND=${current_graphics_backend:-$graphics_backend_request} \
  ROYD_GRAPHICS_ARCH=${current_arch:-x86_64} \
  ROYD_BUILDER_TTY=never \
  ROYD_CLEAN_BUILD=$clean_build \
  "$builder" "$@"
}

validate_stages
validate_arches
validate_versions
mkdir -p "$results_dir"

printf 'royd clean-build matrix\n'
printf '  versions: %s\n' "$(printf '%s' "$versions" | tr '\n' ' ')"
printf '  arches: %s\n' "$arches"
printf '  image profile: %s\n' "$profile"
printf '  HAL profile: %s\n' "$hal_profile"
printf '  graphics backend: %s\n' "$graphics_backend_request"
printf '  stages: %s\n' "$stages"
printf '  clean builds: %s\n' "$clean_build"
printf '  resume: %s\n' "$resume"

for current_version in $versions; do
  src="$work_root/android-src-$current_version"
  sync_status=not-needed
  if [ ! -d "$src/build" ] && [ "$sync_missing" = 1 ]; then
    printf '\n==> Android %s: source tree missing, synchronising\n' "$current_version"
    if run_builder android/scripts/sync.sh; then
      sync_status=pass
    else
      sync_status=fail
      printf 'error: source synchronisation failed for Android %s\n' "$current_version" >&2
      for current_arch in $arches; do
    current_graphics_backend=$(ROYD_ANDROID_VERSION="$current_version" ROYD_GRAPHICS_ARCH="$current_arch" "$script_dir/graphics-backend.sh" "$graphics_backend_request" "$current_arch")
        key=$(result_key "$current_version" "$current_arch" "$profile" "$hal_profile" "$current_graphics_backend")
        result_file="$results_dir/$key"
        started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        finished=$started
        record_result "$result_file" sync-failed not-run not-run not-run "$started" "$finished" unknown unknown
      done
      status=1
      [ "$continue_on_error" = 1 ] || break
      continue
    fi
  elif [ ! -d "$src/build" ]; then
    sync_status=not-run
  fi

  for current_arch in $arches; do
    current_graphics_backend=$(ROYD_ANDROID_VERSION="$current_version" ROYD_GRAPHICS_ARCH="$current_arch" "$script_dir/graphics-backend.sh" "$graphics_backend_request" "$current_arch")
    key=$(result_key "$current_version" "$current_arch" "$profile" "$hal_profile" "$current_graphics_backend")
    result_file="$results_dir/$key"
    log_file=${result_file%.env}.log
    mkdir -p "$(dirname -- "$result_file")"

    expected_profile_policy=$(ROYD_ANDROID_VERSION="$current_version" "$script_dir/profile-policy.sh" "$profile")
    expected_profile_policy_sha256=$(ROYD_ANDROID_VERSION="$current_version" "$script_dir/profile-packages.sh" "$profile" | sha256sum | awk '{print $1}')
    if [ "$resume" = 1 ] \
      && [ "$(result_get "$result_file" RESULT_FORMAT 2>/dev/null || true)" = 2 ] \
      && [ "$(result_get "$result_file" RESULT_STATUS 2>/dev/null || true)" = pass ] \
      && [ "$(result_get "$result_file" PROFILE_POLICY 2>/dev/null || true)" = "$expected_profile_policy" ] \
      && [ "$(result_get "$result_file" PROFILE_POLICY_SHA256 2>/dev/null || true)" = "$expected_profile_policy_sha256" ]; then
      printf '\n==> Android %s %s: already passed with current profile policy, skipping\n' "$current_version" "$current_arch"
      continue
    fi

    started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    config_status=not-run
    build_status=not-run
    package_status=not-run
    result_status=pass
    manifest_sha=unknown
    archive_sha=unknown
    : > "$log_file"

    if [ ! -d "$src/build" ]; then
      result_status=source-missing
      finished=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      record_result "$result_file" "$result_status" "$config_status" "$build_status" "$package_status" "$started" "$finished" "$manifest_sha" "$archive_sha"
      printf '\n==> Android %s %s: source tree missing\n' "$current_version" "$current_arch"
      status=1
      [ "$continue_on_error" = 1 ] || break 2
      continue
    fi

    lock="$work_root/android-manifest-$current_version.lock.xml"
    if [ -f "$lock" ]; then
      manifest_sha=$(sha256sum "$lock" | awk '{print $1}')
    fi

    printf '\n==> Android %s %s: validating\n' "$current_version" "$current_arch"
    if has_stage config; then
      if run_builder android/scripts/config-check.sh "$current_arch" >>"$log_file" 2>&1; then
        config_status=pass
      else
        config_status=fail
        result_status=config-failed
      fi
    fi

    if [ "$result_status" = pass ] && has_stage build; then
      printf '==> Android %s %s: clean build\n' "$current_version" "$current_arch"
      if run_builder android/scripts/build.sh "$current_arch" "$profile" >>"$log_file" 2>&1; then
        build_status=pass
      else
        build_status=fail
        result_status=build-failed
      fi
    fi

    if [ "$result_status" = pass ] && has_stage package; then
      printf '==> Android %s %s: packaging\n' "$current_version" "$current_arch"
      if run_builder android/scripts/package.sh "$current_arch" "$profile" >>"$log_file" 2>&1; then
        package_status=pass
        graphics_suffix=
        [ "$current_graphics_backend" = software ] || graphics_suffix="-$current_graphics_backend"
        package_manifest="$work_root/runtime/android-$current_version/royd-$current_arch-$profile-$hal_profile$graphics_suffix.manifest"
        if [ -f "$package_manifest" ]; then
          archive_sha=$(sed -n 's/^ARCHIVE_SHA256=//p' "$package_manifest" | tail -n 1)
          [ -n "$archive_sha" ] || archive_sha=unknown
        fi
      else
        package_status=fail
        result_status=package-failed
      fi
    fi

    finished=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    record_result "$result_file" "$result_status" "$config_status" "$build_status" "$package_status" "$started" "$finished" "$manifest_sha" "$archive_sha"
    printf '==> Android %s %s: %s\n' "$current_version" "$current_arch" "$result_status"
    if [ "$result_status" != pass ]; then
      printf '    log: %s\n' "$log_file"
      status=1
      [ "$continue_on_error" = 1 ] || break 2
    fi
  done
done

ROYD_BUILD_RESULTS_DIR="$results_dir" ROYD_BUILD_REPORT_OUTPUT="$report" "$script_dir/build-results-report.sh"
printf '\nBuild matrix report: %s\n' "$report"
exit "$status"
