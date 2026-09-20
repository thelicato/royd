#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
status=0
files=$(find . -type f \
  ! -path './.git/*' \
  ! -path './.git' \
  ! -name '*.zip' \
  ! -name '*.patch')
em_dash=$(printf '\342\200\224')
if grep -nH "$em_dash" $files; then
  printf '%s\n' 'error: em dashes are not allowed' >&2
  status=1
fi
if grep -nH '[[:blank:]]$' $files; then
  printf '%s\n' 'error: trailing whitespace found' >&2
  status=1
fi
exit "$status"
