#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1091
. "$script_dir/common.sh"

src=${1:-$(source_dir)}
patch_dir="$android_dir/patches/$AOSP_TAG"
marker="$src/.repo/royd-local-patches.sha256"

if [ ! -d "$patch_dir" ]; then
  rm -f "$marker"
  printf 'No local AOSP patches for %s\n' "$AOSP_TAG"
  exit 0
fi

patches=$(find "$patch_dir" -maxdepth 1 -type f -name '*.patch' -print | sort)
if [ -z "$patches" ]; then
  rm -f "$marker"
  printf 'No local AOSP patches for %s\n' "$AOSP_TAG"
  exit 0
fi

require_command sha256sum
require_command patch
digest=$(cat $patches | sha256sum | awk '{print $1}')
applied_prefix=
if [ -f "$marker" ]; then
  applied=$(cat "$marker")
  if [ "$applied" = "$digest" ]; then
    printf 'Local AOSP patches already applied: %s\n' "$digest"
    exit 0
  fi

  seen=
  for patch in $patches; do
    seen="$seen $patch"
    prefix_digest=$(cat $seen | sha256sum | awk '{print $1}')
    if [ "$prefix_digest" = "$applied" ]; then
      applied_prefix=$patch
      break
    fi
  done
  [ -n "$applied_prefix" ] || fail 'local patch set changed after application; use a fresh Android source tree'
  printf 'Extending repository-owned AOSP patch set for %s\n' "$AOSP_TAG"
else
  printf 'Applying repository-owned AOSP patches for %s\n' "$AOSP_TAG"
fi

skip_applied=${applied_prefix:+yes}
for patch in $patches; do
  if [ -n "$skip_applied" ]; then
    if [ "$patch" = "$applied_prefix" ]; then
      skip_applied=
    fi
    continue
  fi
  printf 'Applying %s\n' "${patch##*/}"
  (
    cd "$src"
    patch --dry-run -p1 < "$patch" >/dev/null
    patch -p1 < "$patch"
  )
done
printf '%s\n' "$digest" > "$marker"
