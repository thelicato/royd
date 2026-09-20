#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

for script in android/scripts/*.sh runtime/scripts/*.sh android/royd/vendor/royd/bin/*; do
  sh -n "$script"
done

for script in android/scripts/*.sh runtime/scripts/*.sh android/royd/vendor/royd/bin/*; do
  [ -x "$script" ] || {
    printf 'error: expected executable script: %s\n' "$script" >&2
    exit 1
  }
done

grep -Fq 'vendor/royd/royd.mk' android/scripts/install-royd.sh
grep -Fq 'exec -- /vendor/bin/royd-binder-setup' android/royd/vendor/royd/init.royd.rc
grep -Fq 'on property:init.svc.logd=running' android/royd/vendor/royd/init.royd.rc
grep -Fq '/proc/1/fd/1' android/royd/vendor/royd/bin/royd-logcat
grep -Fq 'androidboot.use_memfd=true' runtime/scripts/import.sh
