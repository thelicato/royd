#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1091
. "$script_dir/common.sh"

src=${1:-$(source_dir)}
patch_dir="$android_dir/patches/$AOSP_TAG"
marker="$src/.repo/royd-local-patches.sha256"

[ -d "$patch_dir" ] || fail "local patch directory not found: $patch_dir"

patches=$(find "$patch_dir" -maxdepth 1 -type f -name '*.patch' -print | sort)
if [ -z "$patches" ]; then
  rm -f "$marker"
  printf 'No local AOSP patches for %s\n' "$AOSP_TAG"
  exit 0
fi

require_command sha256sum
require_command patch
digest=$(cat $patches | sha256sum | awk '{print $1}')
if [ -f "$marker" ]; then
  applied=$(cat "$marker")
  [ "$applied" = "$digest" ] || fail 'local patch set changed after application; use a fresh Android source tree'
  printf 'Local AOSP patches already applied: %s\n' "$digest"
  exit 0
fi

printf 'Applying repository-owned AOSP patches for %s\n' "$AOSP_TAG"
for patch in $patches; do
  printf 'Applying %s\n' "${patch##*/}"
  (
    cd "$src"
    patch --dry-run -p1 < "$patch" >/dev/null
    patch -p1 < "$patch"
  )
done
printf '%s\n' "$digest" > "$marker"
