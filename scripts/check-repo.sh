#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
status=0
source_files() {
  find . \( -path './.git' -o -path './.work' \) -prune -o -type f \
    ! -name '*.zip' ! -name '*.patch' -print0
}

em_dash=$(printf '\342\200\224')
em_dash_matches=$(source_files | xargs -0 -r grep -nH "$em_dash" || true)
if [ -n "$em_dash_matches" ]; then
  printf '%s\n' "$em_dash_matches"
  printf '%s\n' 'error: em dashes are not allowed' >&2
  status=1
fi
trailing_whitespace_matches=$(source_files | xargs -0 -r grep -nH '[[:blank:]]$' || true)
if [ -n "$trailing_whitespace_matches" ]; then
  printf '%s\n' "$trailing_whitespace_matches"
  printf '%s\n' 'error: trailing whitespace found' >&2
  status=1
fi

prior_art_name=$(printf 're%s' 'droid')
prior_art_matches=$(grep -Rni --exclude-dir=.git --exclude-dir=.work \
  --exclude=acknowledgements.md "$prior_art_name" . 2>/dev/null || true)
if [ -n "$prior_art_matches" ]; then
  printf '%s\n' "$prior_art_matches" >&2
  printf '%s\n' 'error: prior-art name is allowed only in docs/acknowledgements.md' >&2
  status=1
fi
if ! grep -qi "$prior_art_name" docs/acknowledgements.md; then
  printf '%s\n' 'error: prior-art acknowledgement is missing' >&2
  status=1
fi
if grep -RFn '/dev/ashmem' android/compat android/royd android/scripts 2>/dev/null; then
  printf '%s\n' 'error: royd legacy memory compatibility must not require /dev/ashmem' >&2
  status=1
fi
exit "$status"
