#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
android_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM
mkdir -p "$tmp/repo" "$tmp/bin" "$tmp/src"
cp -a "$android_dir" "$tmp/repo/android"

cat > "$tmp/bin/repo" <<'MOCK'
#!/bin/sh
set -eu
printf '%s\n' "$*" >> "$ROYD_REPO_LOG"
case "$1" in
  init)
    mkdir -p .repo
    ;;
  sync)
    mkdir -p build
    ;;
  forall)
    ;;
  manifest)
    output=
    shift
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -o)
          output=$2
          shift 2
          ;;
        *)
          shift
          ;;
      esac
    done
    [ -n "$output" ] || exit 2
    mkdir -p "$(dirname -- "$output")"
    printf '%s\n' '<manifest />' > "$output"
    ;;
  *)
    exit 2
    ;;
esac
MOCK
cat > "$tmp/bin/git-lfs" <<'MOCK'
#!/bin/sh
exit 0
MOCK
chmod +x "$tmp/bin/repo" "$tmp/bin/git-lfs"

: > "$tmp/repo.log"
for pass in 1 2; do
  PATH="$tmp/bin:$PATH" \
  ROYD_REPO_LOG="$tmp/repo.log" \
  ROYD_ANDROID_VERSION=15 \
  ROYD_ANDROID_SRC="$tmp/src" \
  JOBS=1 \
    "$tmp/repo/android/scripts/sync.sh" >/dev/null

done

[ "$(grep -c '^init ' "$tmp/repo.log")" -eq 1 ] || {
  printf '%s\n' 'error: resumable sync reinitialised an existing Repo checkout' >&2
  exit 1
}
[ "$(grep -c '^sync ' "$tmp/repo.log")" -eq 2 ] || {
  printf '%s\n' 'error: expected both sync passes to invoke repo sync' >&2
  exit 1
}
if grep -Fq -- '--git-lfs' "$tmp/repo.log"; then
  printf '%s\n' 'error: sync still passes unsupported repo init --git-lfs' >&2
  exit 1
fi
grep -Fq "forall -c git lfs pull" "$tmp/repo.log" || {
  printf '%s\n' 'error: explicit Git LFS pull step is missing' >&2
  exit 1
}
test -f "$tmp/repo/.work/android-manifest-15.lock.xml"

printf '%s\n' 'Android Repo and Git LFS sync contract test passed'
