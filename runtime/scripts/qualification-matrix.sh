#!/bin/sh
set -u

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
# shellcheck disable=SC1091
. "$script_dir/runtime-result-lib.sh"

versions=${ROYD_QUALIFY_VERSIONS:-$("$repo_root/android/scripts/version-list.sh")}
arches=${ROYD_QUALIFY_ARCHES:-"x86_64 arm64"}
image_profile=${ROYD_ANDROID_PROFILE:-standard}
image_profile=$("$repo_root/android/scripts/profile.sh" "$image_profile")
hal_profile=${ROYD_HAL_PROFILE:-graphical}
hal_profile=$("$repo_root/android/scripts/hal-profile.sh" "$hal_profile")
security_mode=${ROYD_SECURITY_MODE:-privileged}
graphics_backend_request=${ROYD_GRAPHICS_BACKEND:-software}
resume=${ROYD_QUALIFY_RESUME:-1}
continue_on_error=${ROYD_QUALIFY_CONTINUE_ON_ERROR:-1}
require_adb=${ROYD_QUALIFY_REQUIRE_ADB:-1}
work_root=${ROYD_WORK_DIR:-$repo_root/.work}
results_dir=${ROYD_RUNTIME_RESULTS_DIR:-$work_root/runtime-results}
report=${ROYD_RUNTIME_REPORT_OUTPUT:-$results_dir/runtime-qualification.md}
runner=${ROYD_QUALIFY_RUNNER:-$script_dir/qualification.sh}
status=0

case "$resume:$continue_on_error:$require_adb" in
  *[!01:]*)
    printf '%s\n' 'error: ROYD_QUALIFY_RESUME, ROYD_QUALIFY_CONTINUE_ON_ERROR and ROYD_QUALIFY_REQUIRE_ADB must be 0 or 1' >&2
    exit 2
    ;;
esac

for version in $versions; do
  [ -f "$repo_root/android/versions/$version.env" ] || {
    printf 'error: unsupported Android version in ROYD_QUALIFY_VERSIONS: %s\n' "$version" >&2
    exit 2
  }
done
for arch in $arches; do
  case "$arch" in x86_64|arm64) ;; *) printf 'error: unsupported architecture in ROYD_QUALIFY_ARCHES: %s\n' "$arch" >&2; exit 2 ;; esac
done

mkdir -p "$results_dir"
printf 'royd runtime qualification matrix\n'
printf '  versions: %s\n' "$(printf '%s' "$versions" | tr '\n' ' ')"
printf '  arches: %s\n' "$arches"
printf '  image profile: %s\n' "$image_profile"
printf '  HAL profile: %s\n' "$hal_profile"
printf '  security mode: %s\n' "$security_mode"
printf '  graphics backend: %s\n' "$graphics_backend_request"
printf '  resume: %s\n' "$resume"

for version in $versions; do
  for arch in $arches; do
    graphics_backend=$(ROYD_ANDROID_VERSION="$version" ROYD_GRAPHICS_ARCH="$arch" "$repo_root/android/scripts/graphics-backend.sh" "$graphics_backend_request" "$arch")
    key=$(runtime_result_key "$version" "$arch" "$image_profile" "$hal_profile" "$security_mode" "$graphics_backend")
    result_file="$results_dir/$key"
    log_file=${result_file%.env}.log
    if [ "$resume" = 1 ] && [ "$(runtime_result_get "$result_file" RESULT_STATUS 2>/dev/null || true)" = pass ]; then
      printf '\n==> Android %s %s: runtime qualification already passed, skipping\n' "$version" "$arch"
      continue
    fi
    printf '\n==> Android %s %s: runtime qualification\n' "$version" "$arch"
    if ROYD_ANDROID_VERSION="$version" \
      ROYD_QUALIFY_ARCH="$arch" \
      ROYD_ANDROID_PROFILE="$image_profile" \
      ROYD_HAL_PROFILE="$hal_profile" \
      ROYD_SECURITY_MODE="$security_mode" \
      ROYD_GRAPHICS_BACKEND="$graphics_backend" \
      ROYD_QUALIFY_REQUIRE_ADB="$require_adb" \
      ROYD_RUNTIME_RESULTS_DIR="$results_dir" \
      ROYD_RUNTIME_RESULT_FILE="$result_file" \
      ROYD_RUNTIME_LOG_FILE="$log_file" \
      "$runner"; then
      printf '==> Android %s %s: pass\n' "$version" "$arch"
    else
      printf '==> Android %s %s: fail\n' "$version" "$arch" >&2
      status=1
      [ "$continue_on_error" = 1 ] || break 2
    fi
  done
done

ROYD_RUNTIME_RESULTS_DIR="$results_dir" \
ROYD_RUNTIME_REPORT_OUTPUT="$report" \
ROYD_ANDROID_PROFILE="$image_profile" \
ROYD_HAL_PROFILE="$hal_profile" \
ROYD_SECURITY_MODE="$security_mode" \
ROYD_GRAPHICS_BACKEND="$graphics_backend_request" \
"$script_dir/qualification-report.sh" >/dev/null
printf '\nRuntime qualification report: %s\n' "$report"
exit "$status"
