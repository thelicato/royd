#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
mode=${1:-${ROYD_SECURITY_MODE:-privileged}}
field=${2:-id}
profile="$repo_root/runtime/security/$mode.env"
capability_file="$repo_root/runtime/security/$mode.capabilities"

[ -f "$profile" ] || {
  printf 'error: unknown security mode: %s\n' "$mode" >&2
  printf '%s\n' 'supported modes: privileged, experimental' >&2
  exit 2
}

# shellcheck disable=SC1090
. "$profile"

profile_digest() {
  {
    cat "$profile"
    if [ -f "$capability_file" ]; then
      cat "$capability_file"
    fi
  } | sha256sum | awk '{print $1}'
}

case "$field" in
  id) printf '%s\n' "$ROYD_SECURITY_PROFILE_ID" ;;
  digest) profile_digest ;;
  capabilities) printf '%s\n' "$ROYD_CAPABILITIES" ;;
  privileged) printf '%s\n' "$ROYD_SECURITY_PRIVILEGED" ;;
  cap-drop-all) printf '%s\n' "$ROYD_CAP_DROP_ALL" ;;
  file) printf '%s\n' "$profile" ;;
  *)
    printf 'error: unknown security profile field: %s\n' "$field" >&2
    printf '%s\n' 'supported fields: id, digest, capabilities, privileged, cap-drop-all, file' >&2
    exit 2
    ;;
esac
