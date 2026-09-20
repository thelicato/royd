#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
mode=${1:-${ROYD_SECURITY_MODE:-privileged}}
profile="$repo_root/runtime/security/$mode.env"

[ -f "$profile" ] || {
  printf 'error: unknown security mode: %s\n' "$mode" >&2
  printf '%s\n' 'supported modes: privileged, experimental' >&2
  exit 2
}
# shellcheck disable=SC1090
. "$profile"

if [ "$ROYD_SECURITY_PRIVILEGED" = 1 ]; then
  printf '%s\n' '--privileged'
  exit 0
fi

if [ "$ROYD_CAP_DROP_ALL" = 1 ]; then
  printf '%s\n' '--cap-drop=ALL'
fi

capabilities=$ROYD_CAPABILITIES
if [ "${ROYD_CAPABILITIES_OVERRIDE+x}" = x ]; then
  capabilities=$ROYD_CAPABILITIES_OVERRIDE
fi
for capability in $capabilities; do
  printf '%s\n' "--cap-add=$capability"
done
