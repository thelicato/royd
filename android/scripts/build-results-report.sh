#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
android_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
repo_root=$(CDPATH= cd -- "$android_dir/.." && pwd)
# shellcheck disable=SC1091
. "$script_dir/build-result-lib.sh"

work_root=${ROYD_WORK_DIR:-$repo_root/.work}
results_dir=${ROYD_BUILD_RESULTS_DIR:-$work_root/build-results}
output=${ROYD_BUILD_REPORT_OUTPUT:-}
profile=${ROYD_ANDROID_PROFILE:-standard}
profile=$("$script_dir/profile.sh" "$profile")
hal_profile=${ROYD_HAL_PROFILE:-graphical}
hal_profile=$("$script_dir/hal-profile.sh" "$hal_profile")

emit() {
  printf '%s\n' "$*"
}

render() {
  emit '# royd clean-build results'
  emit ''
  emit 'A passing row means the selected AOSP tree resolved the royd product contract, compiled cleanly when the build stage was requested, and packaged successfully when the package stage was requested. Runtime support requires separate boot validation.'
  emit ''
  emit "Image profile: \`$profile\`"
  emit "HAL profile: \`$hal_profile\`"
  emit ''
  emit '| Android | Arch | Config | Build | Package | Result | Manifest provenance | Archive |'
  emit '| --- | --- | --- | --- | --- | --- | --- | --- |'
  for version in $("$script_dir/version-list.sh"); do
    for arch in x86_64 arm64; do
      file="$results_dir/$(result_key "$version" "$arch" "$profile" "$hal_profile")"
      if [ -f "$file" ]; then
        config=$(result_get "$file" CONFIG_STATUS || printf unknown)
        build=$(result_get "$file" BUILD_STATUS || printf unknown)
        package=$(result_get "$file" PACKAGE_STATUS || printf unknown)
        result=$(result_get "$file" RESULT_STATUS || printf unknown)
        manifest=$(result_get "$file" AOSP_MANIFEST_SHA256 || printf unknown)
        archive=$(result_get "$file" ARCHIVE_SHA256 || printf unknown)
        [ "$manifest" = unknown ] || manifest=$(printf '%.12s' "$manifest")
        [ "$archive" = unknown ] || archive=$(printf '%.12s' "$archive")
      else
        config=not-run
        build=not-run
        package=not-run
        result=not-run
        manifest=unknown
        archive=unknown
      fi
      emit "| $version | $arch | $config | $build | $package | $result | $manifest | $archive |"
    done
  done
  emit ''
  emit '## Promotion gate'
  emit ''
  emit 'These records are build evidence only. A version must also pass OCI import, container boot, Binder isolation, graphics, ADB, memory, and security validation before its support status can be promoted.'
}

if [ -n "$output" ]; then
  mkdir -p "$(dirname -- "$output")"
  render > "$output"
  printf 'Build results report written to %s\n' "$output"
else
  render
fi
