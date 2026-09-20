#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1091
. "$script_dir/common.sh"

require_command git
require_command repo
require_command git-lfs

src=$(source_dir)
patches=$(patches_dir)
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

if [ ! -d "$src/.repo/local_manifests/.git" ]; then
  rm -rf "$src/.repo/local_manifests"
  printf 'Adding ReDroid manifest branch %s\n' "$REDROID_MANIFEST_BRANCH"
  git clone \
    --depth=1 \
    --branch "$REDROID_MANIFEST_BRANCH" \
    "$REDROID_MANIFEST_URL" \
    "$src/.repo/local_manifests"
fi

printf 'Synchronising Android sources with %s jobs\n' "$jobs"
(
  cd "$src"
  repo sync -c -j"$jobs"
  repo forall -c 'git lfs pull'
)

if [ ! -d "$patches/.git" ]; then
  rm -rf "$patches"
  printf 'Cloning ReDroid patches at %s\n' "$REDROID_PATCHES_REF"
  git clone "$REDROID_PATCHES_URL" "$patches"
fi

git -C "$patches" fetch --depth=1 origin "$REDROID_PATCHES_REF"
git -C "$patches" checkout --detach FETCH_HEAD
patch_commit=$(git -C "$patches" rev-parse HEAD)
patch_marker="$src/.repo/royd-redroid-patches.commit"

[ -d "$patches/$AOSP_TAG" ] || fail "ReDroid has no patch set for $AOSP_TAG"
if [ -f "$patch_marker" ]; then
  applied_patch_commit=$(cat "$patch_marker")
  [ "$applied_patch_commit" = "$patch_commit" ] || fail "source tree already contains ReDroid patches from $applied_patch_commit; use a fresh source tree before changing patch revisions"
  printf 'ReDroid patches already applied at %s\n' "$patch_commit"
else
  printf 'Applying ReDroid patches for %s at %s\n' "$AOSP_TAG" "$patch_commit"
  "$patches/apply-patch.sh" "$src" "$AOSP_TAG"
  if ! (
    cd "$src"
    repo forall -c 'test ! -d "$(git rev-parse --git-path rebase-apply)"'
  ); then
    fail 'ReDroid patch application left at least one project in a failed git am state'
  fi
  printf '%s\n' "$patch_commit" > "$patch_marker"
fi

printf 'Writing resolved source manifest\n'
(
  cd "$src"
  repo manifest -r -o "$repo_root/.work/android-manifest.lock.xml"
)

printf 'Android source baseline is ready at %s\n' "$src"
printf 'Resolved manifest: %s\n' "$repo_root/.work/android-manifest.lock.xml"
