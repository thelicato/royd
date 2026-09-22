#!/bin/sh
set -eu

binder_identity_get() {
  data=$1
  path=$2
  printf '%s\n' "$data" | sed -n "s|^$path=||p" | tail -n 1
}

binder_identities_isolated() {
  first=$1
  second=$2
  for path in /dev/royd-binderfs/binder-control /dev/binder /dev/hwbinder /dev/vndbinder; do
    a=$(binder_identity_get "$first" "$path")
    b=$(binder_identity_get "$second" "$path")
    [ -n "$a" ] && [ -n "$b" ] || return 1
    [ "$a" != "$b" ] || return 1
  done
}
