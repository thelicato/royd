#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
android_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
repo_root=$(CDPATH= cd -- "$android_dir/.." && pwd)
# shellcheck disable=SC1091
. "$script_dir/build-result-lib.sh"
# shellcheck disable=SC1091
. "$repo_root/runtime/scripts/runtime-result-lib.sh"

output=${ROYD_MATRIX_OUTPUT:-}
strict=${ROYD_MATRIX_STRICT:-0}
require_build=${ROYD_MATRIX_REQUIRE_BUILD:-0}
require_runtime=${ROYD_MATRIX_REQUIRE_RUNTIME:-0}
work_root=${ROYD_MATRIX_SOURCE_ROOT:-$repo_root/.work}
results_dir=${ROYD_BUILD_RESULTS_DIR:-$work_root/build-results}
runtime_results_dir=${ROYD_RUNTIME_RESULTS_DIR:-$work_root/runtime-results}
runtime_security_mode=${ROYD_MATRIX_SECURITY_MODE:-privileged}
graphics_backend=${ROYD_GRAPHICS_BACKEND:-software}
profile=${ROYD_ANDROID_PROFILE:-standard}
profile=$("$script_dir/profile.sh" "$profile")
hal_profile=${ROYD_HAL_PROFILE:-graphical}
hal_profile=$("$script_dir/hal-profile.sh" "$hal_profile")
status=0

case "$strict:$require_build:$require_runtime" in
  *[!01:]*)
    printf '%s\n' 'error: ROYD_MATRIX_STRICT, ROYD_MATRIX_REQUIRE_BUILD and ROYD_MATRIX_REQUIRE_RUNTIME must be 0 or 1' >&2
    exit 1
    ;;
esac

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT INT TERM

append() {
  printf '%s\n' "$*" >> "$tmp"
}

append '# royd Android compatibility matrix'
append ''
append 'This report separates repository configuration, resolved AOSP validation, clean-build evidence, package evidence, and persisted runtime qualification. None of these columns alone imply support.'
append ''
append "Image profile: \`$profile\`"
append "HAL profile: \`$hal_profile\`"
append "Graphics backend: \`$graphics_backend\`"
append ''
append '| Android | AOSP tag | Family | Builder | Arch | Source | Config | Build | Package | Runtime | Status |'
append '| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |'

for version in $("$script_dir/version-list.sh"); do
  env_file="$android_dir/versions/$version.env"
  # shellcheck disable=SC1090
  . "$env_file"
  src="$work_root/android-src-$version"
  if [ -d "$src/build" ]; then
    source_state=present
  else
    source_state=missing
  fi

  for arch in x86_64 arm64; do
    resolved=not-run
    build_state=not-run
    package_state=not-run
    runtime_state=not-run
    row_status=$ANDROID_SUPPORT_STATUS
    result_file="$results_dir/$(result_key "$version" "$arch" "$profile" "$hal_profile" "$graphics_backend")"
    runtime_file="$runtime_results_dir/$(runtime_result_key "$version" "$arch" "$profile" "$hal_profile" "$runtime_security_mode" "$graphics_backend")"

    if [ "$source_state" = present ]; then
      if ROYD_ANDROID_VERSION="$version" ROYD_ANDROID_SRC="$src" ROYD_GRAPHICS_BACKEND="$graphics_backend" ROYD_GRAPHICS_ARCH="$arch" "$script_dir/config-check.sh" "$arch" >/dev/null 2>&1; then
        resolved=pass
      else
        resolved=fail
        row_status=config-failed
        status=1
      fi
    elif [ "$strict" = 1 ]; then
      row_status=source-missing
      status=1
    fi

    if [ -f "$result_file" ]; then
      build_state=$(result_get "$result_file" BUILD_STATUS || printf unknown)
      package_state=$(result_get "$result_file" PACKAGE_STATUS || printf unknown)
      result_state=$(result_get "$result_file" RESULT_STATUS || printf unknown)
      if [ "$result_state" != pass ]; then
        row_status=$result_state
      elif [ "$package_state" = pass ]; then
        row_status=package-validated
      elif [ "$build_state" = pass ]; then
        row_status=build-validated
      fi
    fi

    if [ -f "$runtime_file" ]; then
      runtime_state=$(runtime_result_get "$runtime_file" RESULT_STATUS || printf unknown)
      if [ "$runtime_state" = pass ]; then
        row_status=runtime-qualified
      elif [ "$runtime_state" != not-run ]; then
        row_status=runtime-failed
      fi
    fi

    if [ "$require_build" = 1 ]; then
      if [ "$build_state" != pass ]; then
        status=1
        [ "$row_status" = "$ANDROID_SUPPORT_STATUS" ] && row_status=build-required
      fi
    fi
    if [ "$require_runtime" = 1 ] && [ "$runtime_state" != pass ]; then
      status=1
      case "$row_status" in
        "$ANDROID_SUPPORT_STATUS"|build-validated|package-validated) row_status=runtime-required ;;
      esac
    fi

    append "| $version | \`$AOSP_TAG\` | $ANDROID_PRODUCT_FAMILY | $ANDROID_BUILDER_FAMILY | $arch | $source_state | $resolved | $build_state | $package_state | $runtime_state | $row_status |"
  done
done

append ''
append '## Interpretation'
append ''
append '- `present` means a source tree exists at the expected version-specific path.'
append '- Config `pass` means royd installed its integration and AOSP resolved the expected product contract for that architecture.'
append '- Build `pass` is recorded only by the clean-build matrix runner after an actual compile.'
append '- Package `pass` is recorded only after OCI root filesystem packaging completes and its archive digest is captured.'
append '- Runtime `pass` means the persisted runtime qualification gate passed for the selected security mode.'
append '- Memory workload evidence and reviewed reference-host records remain separate release gates.'
append '- `ROYD_MATRIX_REQUIRE_BUILD=1` makes missing or failed clean-build evidence fatal.'
append '- `ROYD_MATRIX_REQUIRE_RUNTIME=1` makes missing or failed runtime qualification evidence fatal.'

if [ -n "$output" ]; then
  mkdir -p "$(dirname -- "$output")"
  cp "$tmp" "$output"
  printf 'Android compatibility matrix written to %s\n' "$output"
else
  cat "$tmp"
fi

exit "$status"
