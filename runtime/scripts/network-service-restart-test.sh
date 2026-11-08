#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
export PYTHONDONTWRITEBYTECODE=1
export ROYD_QUOTA_NETWORK_MODE=bridge
export ROYD_QUOTA_PACKET_HEADERS=0
export ROYD_QUOTA_OUTPUT_DIR=${ROYD_NETWORK_RESTART_OUTPUT_DIR:-$root/.work/network-service-restart-$(date -u +%Y%m%dT%H%M%SZ)-$$}
exec python3 "$root/runtime/tests/network-restart/service_restart.py" "$@"
