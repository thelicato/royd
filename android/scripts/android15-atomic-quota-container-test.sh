#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
export PYTHONDONTWRITEBYTECODE=1
python3 "$root/android/tests/network-quota-atomic.py" "$root"
printf '%s\n' 'Android 15 atomic OCI interface-quota replacement contracts passed'
