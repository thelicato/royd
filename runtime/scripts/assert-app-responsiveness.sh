#!/bin/sh
set -eu

container=${1:-royd}
log=$(mktemp)
trap 'rm -f "$log"' EXIT HUP INT TERM
# Inspect the complete retained history, including events before a recovered process.
if ! docker logs "$container" >"$log" 2>&1; then
  printf 'error: could not read application responsiveness history in %s\n' "$container" >&2
  exit 1
fi
pattern='(^|[[:space:]])(am_anr[[:space:]]*:|WindowManager[[:space:]]*: ANR in |ActivityManager[[:space:]]*: ANR in |InputDispatcher[[:space:]]*: Window .* is unresponsive:)'
if grep -Eq "$pattern" "$log"; then
  printf 'error: Android 15 retained application ANR or input timeout diagnostics in %s\n' "$container" >&2
  grep -E "$pattern" "$log" >&2
  exit 1
fi
