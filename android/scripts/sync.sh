#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1091
. "$script_dir/common.sh"

require_command repo
require_command git-lfs

src=$(source_dir)
jobs=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '4')}

mkdir -p "$src"
if [ ! -d "$src/.repo" ]; then
  printf 'Initialising AOSP %s in %s\n' "$AOSP_TAG" "$src"
  (
    cd "$src"
    repo init \
      -u "$AOSP_MANIFEST_URL" \
      -b "$AOSP_TAG" \
      --depth=1 \
      --git-lfs
  )
fi

printf 'Synchronising AOSP sources with %s jobs\n' "$jobs"
(
  cd "$src"
  repo sync -c -j"$jobs"
  repo forall -c 'git lfs pull'
)

"$script_dir/apply-patches.sh" "$src"
"$script_dir/install-royd.sh" "$src"

printf 'Writing resolved AOSP source manifest\n'
(
  cd "$src"
  repo manifest -r -o "$repo_root/.work/android-manifest.lock.xml"
)

printf 'Android source baseline is ready at %s\n' "$src"
printf 'Resolved manifest: %s\n' "$repo_root/.work/android-manifest.lock.xml"
