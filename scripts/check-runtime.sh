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
grep -Fq 'ro.config.low_ram=true' android/royd/vendor/royd/royd.mk
grep -Fq 'ro.lmk.use_psi=true' android/royd/vendor/royd/royd.mk
grep -Fq 'ro.lmk.use_minfree_levels=false' android/royd/vendor/royd/royd.mk
grep -Fq 'androidboot.use_memfd=true' runtime/scripts/import.sh
grep -Fq 'androidboot.redroid_width=540' runtime/scripts/import.sh
grep -Fq 'androidboot.redroid_height=960' runtime/scripts/import.sh
grep -Fq "CMD [\"androidboot.redroid_width=540\"" runtime/scripts/import.sh
grep -Fq 'docker stats --no-stream' runtime/scripts/memory-report.sh

grep -Fq 'sys.boot_completed' runtime/scripts/wait-for-boot.sh
grep -Fq '[ -c /dev/binder ]' runtime/scripts/assert-runtime.sh
grep -Fq 'runtime-smoke-test' Makefile
grep -Fq 'runtime-multi-test' Makefile
grep -Fq 'android-b:' runtime/compose.multi.yaml
grep -Fq 'logo.svg' README.md
