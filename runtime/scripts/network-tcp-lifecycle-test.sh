#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
export PYTHONDONTWRITEBYTECODE=1 ROYD_QUOTA_NETWORK_MODE=isolated ROYD_QUOTA_PACKET_HEADERS=1
exec python3 "$root/runtime/tests/network-quota/diagnose_tcp.py" "$@"
