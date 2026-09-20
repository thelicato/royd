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
grep -Fq 'runtime-up' Makefile
grep -Fq 'runtime-down' Makefile
grep -Fq 'runtime-logs' Makefile
grep -Fq 'runtime-ps' Makefile
grep -Fq 'ROYD_IMAGE' runtime/compose.yaml
grep -Fq 'ROYD_ADB_PORT' runtime/compose.yaml
grep -Fq 'exec docker compose' runtime/scripts/compose.sh

grep -Fq 'runtime-reference-report' Makefile
grep -Fq 'Single-instance smoke test' runtime/scripts/reference-report.sh
grep -Fq 'Two-instance smoke test' runtime/scripts/reference-report.sh
grep -Fq 'CONFIG_ANDROID_BINDERFS' runtime/scripts/reference-report.sh
grep -Fq 'memory-sweep' Makefile
grep -Fq 'ROYD_WIDTH' runtime/compose.yaml
grep -Fq 'ROYD_HEIGHT' runtime/compose.yaml
grep -Fq 'ROYD_DPI' runtime/compose.yaml
grep -Fq 'ROYD_FPS' runtime/compose.yaml
grep -Fq 'ROYD_WIDTH=540' runtime/profiles/default.env
grep -Fq 'androidboot.redroid_width' runtime/scripts/profile.sh
grep -Fq 'ROYD_MEMORY_LIMITS' runtime/scripts/memory-sweep.sh
