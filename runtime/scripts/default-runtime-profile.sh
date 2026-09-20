#!/bin/sh
set -eu

hal_profile=${ROYD_HAL_PROFILE:-graphical}
case "$hal_profile" in
  graphical) printf '%s\n' default ;;
  headless) printf '%s\n' headless ;;
  *)
    printf 'error: unsupported HAL profile: %s\n' "$hal_profile" >&2
    exit 2
    ;;
esac
