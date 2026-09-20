#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
mode=${1:-${ROYD_SECURITY_MODE:-privileged}}

case "$mode" in
  privileged)
    printf '%s\n' '--privileged'
    ;;
  experimental)
    # shellcheck disable=SC1091
    . "$repo_root/runtime/security/experimental.env"
    for capability in $ROYD_CAPABILITIES; do
      printf '%s\n' "--cap-add=$capability"
    done
    ;;
  *)
    printf 'error: unknown security mode: %s\n' "$mode" >&2
    printf '%s\n' 'supported modes: privileged, experimental' >&2
    exit 2
    ;;
esac
