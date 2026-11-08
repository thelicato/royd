#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
export PYTHONDONTWRITEBYTECODE=1
export ROYD_QUOTA_NETWORK_MODE=isolated
export ROYD_QUOTA_PACKET_HEADERS=1
export ROYD_QUOTA_OUTPUT_DIR=${ROYD_POLICY_USAGE_OUTPUT_DIR:-$root/.work/network-policy-usage-$(date -u +%Y%m%dT%H%M%SZ)-$$}
exec python3 "$root/runtime/tests/network-policy-usage/policy_usage.py" "$@"
