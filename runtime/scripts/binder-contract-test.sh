#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
setup="$root/android/royd/vendor/royd/bin/royd-binder-setup"
info="$root/android/royd/vendor/royd/binder_info/royd-binder-info.c"
diagnostics="$root/android/royd/vendor/royd/bin/royd-diagnostics"
assert_runtime="$root/runtime/scripts/assert-runtime.sh"
identity="$root/runtime/scripts/binder-identity-lib.sh"

# Android mounts its own binderfs at /dev/binderfs during init. Keep royd's
# private instance at a non-conflicting path so early allocations stay visible.
grep -Fx 'binderfs=/dev/royd-binderfs' "$setup" >/dev/null
if grep -Fxq 'binderfs=/dev/binderfs' "$setup"; then
  echo 'error: royd private binderfs still uses Android mountpoint' >&2
  exit 1
fi
grep -F 'chmod 0666 "$target"' "$setup" >/dev/null
grep -F '"/dev/royd-binderfs/binder-control",' "$info" >/dev/null
grep -F '/dev/royd-binderfs' "$diagnostics" >/dev/null
grep -F " /dev/royd-binderfs binder " "$assert_runtime" >/dev/null
grep -F '/dev/royd-binderfs/binder-control' "$identity" >/dev/null

printf '%s\n' 'Binder private-mount contract test passed'
