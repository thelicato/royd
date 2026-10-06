#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

mkdir -p "$tmp/repo/scripts" "$tmp/repo/docs" "$tmp/repo/src" "$tmp/repo/.work/generated"
cp "$root/scripts/check-repo.sh" "$tmp/repo/scripts/check-repo.sh"
prior_art_name=$(printf 're%s' 'droid')
printf '%s acknowledgement fixture\n' "$prior_art_name" > "$tmp/repo/docs/acknowledgements.md"
printf '%s\n' 'clean source' > "$tmp/repo/src/clean.txt"
printf 'ignored em dash \342\200\224 and trailing whitespace \n%s /dev/ashmem\n' \
  "$prior_art_name" > "$tmp/repo/.work/generated/build-output.txt"

"$tmp/repo/scripts/check-repo.sh"

printf '%s \n' 'bad source' > "$tmp/repo/src/bad.txt"
if "$tmp/repo/scripts/check-repo.sh" >"$tmp/error" 2>&1; then
  printf '%s\n' 'error: repository check accepted trailing whitespace in source' >&2
  exit 1
fi
grep -Fq 'error: trailing whitespace found' "$tmp/error"

printf '%s\n' 'Repository hygiene check contract passed'
