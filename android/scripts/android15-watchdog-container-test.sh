#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
PYTHONDONTWRITEBYTECODE=1 python3 "$root/android/tests/watchdog-container-test.py" "$root" "$tmp"
PYTHONDONTWRITEBYTECODE=1 python3 "$root/android/tests/watchdog-timing-test.py" "$root" "$tmp/timing"
