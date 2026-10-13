#!/bin/sh
set -eu

profile=${1:-${ROYD_RESOURCE_PROFILE:-low-memory}}

case "$profile" in
  low-memory|performance)
    printf 'royd.resource_profile=%s\n' "$profile"
    ;;
  *)
    printf 'error: unknown resource profile: %s\n' "$profile" >&2
    printf '%s\n' 'available resource profiles: low-memory performance' >&2
    exit 2
    ;;
esac
