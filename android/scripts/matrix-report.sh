#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
android_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
repo_root=$(CDPATH= cd -- "$android_dir/.." && pwd)

output=${ROYD_MATRIX_OUTPUT:-}
strict=${ROYD_MATRIX_STRICT:-0}
work_root=${ROYD_MATRIX_SOURCE_ROOT:-$repo_root/.work}
status=0

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT INT TERM

append() {
  printf '%s\n' "$*" >> "$tmp"
}

append '# royd Android compatibility matrix'
append ''
append 'This report separates repository configuration from resolved AOSP validation. A configured row is not evidence of a successful Android build or boot.'
append ''
append '| Android | AOSP tag | Family | Builder | Arch | Source tree | Resolved config | Status |'
append '| --- | --- | --- | --- | --- | --- | --- | --- |'

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
    row_status=$ANDROID_SUPPORT_STATUS
    if [ "$source_state" = present ]; then
      if ROYD_ANDROID_VERSION="$version" ROYD_ANDROID_SRC="$src" "$script_dir/config-check.sh" "$arch" >/dev/null 2>&1; then
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
    append "| $version | \`$AOSP_TAG\` | $ANDROID_PRODUCT_FAMILY | $ANDROID_BUILDER_FAMILY | $arch | $source_state | $resolved | $row_status |"
  done
done

append ''
append '## Interpretation'
append ''
append '- `present` means a source tree exists at the expected version-specific path.'
append '- `pass` means royd installed its integration and AOSP resolved the expected product contract for that architecture.'
append '- `not-run` means the source tree is not available locally, so only repository metadata has been validated.'
append '- A clean compile, OCI package, container boot, graphics, Binder, ADB, memory, and security validation are separate release gates.'

if [ -n "$output" ]; then
  mkdir -p "$(dirname -- "$output")"
  cp "$tmp" "$output"
  printf 'Android compatibility matrix written to %s\n' "$output"
else
  cat "$tmp"
fi

exit "$status"
