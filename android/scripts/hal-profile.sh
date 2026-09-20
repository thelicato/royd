#!/bin/sh
set -eu
profile=${1:-${ROYD_HAL_PROFILE:-graphical}}
case "$profile" in
  graphical|headless)
    printf '%s\n' "$profile"
    ;;
  *)
    printf 'error: unsupported HAL profile: %s; expected graphical or headless\n' "$profile" >&2
    exit 1
    ;;
esac
