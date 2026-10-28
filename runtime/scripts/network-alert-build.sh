#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
exec "$root/runtime/scripts/network-netd-probe-build.sh" "${1:?new output directory required}" "$root/runtime/tests/network-alert/GlobalAlertProbe.java"
