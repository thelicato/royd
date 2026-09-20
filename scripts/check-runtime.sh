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

grep -Fq 'AOSP_TAG=android-15.0.0_r36' android/baseline.env
grep -Fq 'ANDROID_PRODUCT_X86_64=royd_x86_64' android/baseline.env
grep -Fq 'ANDROID_PRODUCT_ARM64=royd_arm64' android/baseline.env
! grep -Fq 'REDROID_' android/baseline.env
grep -Fq 'royd_x86_64-bp1a-userdebug' android/royd/device/royd/AndroidProducts.mk
grep -Fq 'royd_arm64-bp1a-userdebug' android/royd/device/royd/AndroidProducts.mk
grep -Fq 'vendor/royd/royd.mk' android/royd/device/royd/royd_x86_64.mk
grep -Fq 'royd-binder-alloc' android/royd/vendor/royd/Android.bp
grep -Fq 'BINDER_CTL_ADD' android/royd/vendor/royd/binder_alloc/royd-binder-alloc.c
grep -Fq '/vendor/bin/royd-binder-alloc' android/royd/vendor/royd/bin/royd-binder-setup
grep -Fq 'exec -- /vendor/bin/royd-binder-setup' android/royd/vendor/royd/init.royd.rc
grep -Fq 'on property:init.svc.logd=running' android/royd/vendor/royd/init.royd.rc
grep -Fq 'on property:sys.boot_completed=1' android/royd/vendor/royd/init.royd.rc
grep -Fq '/proc/1/fd/1' android/royd/vendor/royd/bin/royd-logcat
grep -Fq 'ro.boot.royd_width' android/royd/vendor/royd/bin/royd-display-setup
grep -Fq 'ro.config.low_ram=true' android/royd/vendor/royd/royd.mk
grep -Fq 'ro.lmk.use_psi=true' android/royd/vendor/royd/royd.mk
grep -Fq 'ro.lmk.use_minfree_levels=false' android/royd/vendor/royd/royd.mk
grep -Fq 'androidboot.hardware=royd' runtime/scripts/import.sh
grep -Fq 'androidboot.royd_width=540' runtime/scripts/import.sh
grep -Fq 'androidboot.royd_height=960' runtime/scripts/import.sh
grep -Fq 'androidboot.royd_width' runtime/scripts/profile.sh
grep -Fq 'androidboot.royd_width' runtime/compose.yaml
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
grep -Fq 'ROYD_WIDTH=540' runtime/profiles/default.env
grep -Fq 'ROYD_MEMORY_LIMITS' runtime/scripts/memory-sweep.sh
grep -Fq 'vendor/royd/profile.mk' android/royd/vendor/royd/royd.mk
grep -Fq 'BasicDreams' android/profiles/minimal.mk
grep -Fq 'PrintSpooler' android/profiles/minimal.mk
grep -Fq 'ro.vendor.royd.image_profile=minimal' android/profiles/minimal.mk
grep -Fq 'installclean' android/scripts/build.sh
grep -Fq 'android-build-minimal-x86_64' Makefile
grep -Fq 'runtime-import-minimal-x86_64' Makefile
grep -Fq 'image-profile-sweep' Makefile
grep -Fq 'ro.vendor.royd.image_profile' runtime/scripts/memory-sweep.sh
grep -Fq 'android/patches' docs/building.md

grep -Rni 'remote-android\|redroid-patches\|vendor_redroid\|device_redroid\|androidboot.redroid\|REDROID_' \
  android runtime cli scripts docs README.md AGENTS.md \
  --exclude=acknowledgements.md --exclude=check-runtime.sh >/tmp/royd-forbidden-dependencies.txt && {
    cat /tmp/royd-forbidden-dependencies.txt >&2
    printf '%s\n' 'error: forbidden ReDroid dependency reference found outside acknowledgements' >&2
    exit 1
  }
rm -f /tmp/royd-forbidden-dependencies.txt
