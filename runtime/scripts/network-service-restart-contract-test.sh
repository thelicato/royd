#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
export PYTHONDONTWRITEBYTECODE=1
sh -n "$root/runtime/scripts/network-service-restart-test.sh" "$root/runtime/scripts/network-interface-alert-restart-test.sh" "$root/runtime/scripts/framework-restart.sh" "$root/runtime/scripts/framework-restart-transition.sh"
python3 -m unittest discover -s "$root/runtime/tests/network-restart" -p '*_test.py'
"$root/runtime/scripts/framework-restart-contract-test.sh"
