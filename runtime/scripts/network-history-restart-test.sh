#!/bin/sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
export ROYD_RESTART_HISTORY=1
exec "$script_dir/restart-test.sh" "$@"
