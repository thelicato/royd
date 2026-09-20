#!/bin/sh
set -eu

result_key() {
  version=$1
  arch=$2
  profile=$3
  hal_profile=$4
  printf '%s/%s-%s-%s.env\n' "$version" "$arch" "$profile" "$hal_profile"
}

result_get() {
  file=$1
  key=$2
  [ -f "$file" ] || return 1
  sed -n "s/^$key=//p" "$file" | tail -n 1
}

result_write() {
  file=$1
  shift
  mkdir -p "$(dirname -- "$file")"
  tmp="$file.tmp.$$"
  : > "$tmp"
  for item in "$@"; do
    printf '%s\n' "$item" >> "$tmp"
  done
  mv "$tmp" "$file"
}
