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
grep -Fq 'royd_x86_64-bp1a-userdebug' android/royd/device/royd/AndroidProducts.mk
grep -Fq 'royd_arm64-bp1a-userdebug' android/royd/device/royd/AndroidProducts.mk
grep -Fq 'vendor/royd/royd.mk' android/royd/device/royd/royd_x86_64.mk
grep -Fq 'device/royd/container_common.mk' android/royd/device/royd/royd_x86_64.mk
grep -Fq 'device/royd/container_common.mk' android/royd/device/royd/royd_arm64.mk
grep -Fq 'core_64_bit.mk' android/royd/device/royd/container_common.mk
grep -Fq 'generic_system.mk' android/royd/device/royd/container_common.mk
grep -Fq 'base_vendor.mk' android/royd/device/royd/container_common.mk
grep -Fq 'TARGET_NO_KERNEL := true' android/royd/device/royd/royd_x86_64/BoardConfig.mk
grep -Fq 'TARGET_ARCH := x86_64' android/royd/device/royd/royd_x86_64/BoardConfig.mk
grep -Fq 'TARGET_NO_KERNEL := true' android/royd/device/royd/royd_arm64/BoardConfig.mk
grep -Fq 'TARGET_ARCH := arm64' android/royd/device/royd/royd_arm64/BoardConfig.mk
grep -Fq 'BOARD_SYSTEMIMAGE_FILE_SYSTEM_TYPE := ext4' android/royd/device/royd/royd_x86_64/BoardConfig.mk
grep -Fq 'BOARD_VENDORIMAGE_FILE_SYSTEM_TYPE := ext4' android/royd/device/royd/royd_x86_64/BoardConfig.mk
grep -Fq 'BOARD_SYSTEM_EXTIMAGE_FILE_SYSTEM_TYPE := ext4' android/royd/device/royd/royd_x86_64/BoardConfig.mk
grep -Fq 'BOARD_PRODUCTIMAGE_FILE_SYSTEM_TYPE := ext4' android/royd/device/royd/royd_x86_64/BoardConfig.mk
grep -Fq 'TARGET_COPY_OUT_PRODUCT := product' android/royd/device/royd/royd_x86_64/BoardConfig.mk
grep -Fq 'BOARD_SYSTEMIMAGE_FILE_SYSTEM_TYPE := ext4' android/royd/device/royd/royd_arm64/BoardConfig.mk
grep -Fq 'BOARD_VENDORIMAGE_FILE_SYSTEM_TYPE := ext4' android/royd/device/royd/royd_arm64/BoardConfig.mk
grep -Fq 'BOARD_SYSTEM_EXTIMAGE_FILE_SYSTEM_TYPE := ext4' android/royd/device/royd/royd_arm64/BoardConfig.mk
grep -Fq 'BOARD_PRODUCTIMAGE_FILE_SYSTEM_TYPE := ext4' android/royd/device/royd/royd_arm64/BoardConfig.mk
grep -Fq 'TARGET_COPY_OUT_PRODUCT := product' android/royd/device/royd/royd_arm64/BoardConfig.mk
grep -Fq 'PRODUCT_USE_DYNAMIC_PARTITION_SIZE := true' android/royd/device/royd/container_common.mk
grep -Fq 'TARGET_NO_KERNEL=true' android/build-contract.env
grep -Fq 'BOARD_PRODUCTIMAGE_FILE_SYSTEM_TYPE=ext4' android/build-contract.env
grep -Fq 'get_build_var' android/scripts/config-check.sh
grep -Fq 'Android build contract checks passed' android/scripts/config-check.sh
grep -Fq 'append_image system_ext system_ext yes' android/scripts/package.sh
grep -Fq 'append_image product product yes' android/scripts/package.sh
grep -Fq 'android-config-check' Makefile
grep -Fq 'android-config-check-test' Makefile
grep -Fq 'Android resolved build contract test passed' android/scripts/config-check-test.sh
grep -Fq 'android-contract-test' Makefile
! grep -Fq 'aosp_x86_64.mk' android/royd/device/royd/royd_x86_64.mk
! grep -Fq 'aosp_arm64.mk' android/royd/device/royd/royd_arm64.mk
! grep -Fq 'emulator_vendor.mk' android/royd/device/royd/royd_x86_64.mk
! grep -Fq 'emulator_vendor.mk' android/royd/device/royd/royd_arm64.mk
! grep -R -Fq 'board/generic_x86_64/device.mk' android/royd/device/royd
! grep -R -Fq 'board/generic_arm64/device.mk' android/royd/device/royd
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
grep -Fq 'org.opencontainers.image.title=royd' runtime/scripts/import.sh
grep -Fq 'org.royd.image-format' runtime/scripts/import.sh
grep -Fq 'ARCHIVE_SHA256' android/scripts/package.sh
grep -Fq 'ROYD_IMAGE_FORMAT=1' runtime/image.env
grep -Fq 'royd:15.0.0-r36-standard-amd64' runtime/scripts/image-contract-test.sh
grep -Fq '/royd-release' runtime/scripts/image-inspect.sh
grep -Fq 'runtime-image-contract-test' Makefile
grep -Fq 'androidboot.royd_width' runtime/scripts/profile.sh
grep -Fq 'androidboot.royd_width' runtime/compose.yaml
grep -Fq 'docker stats --no-stream' runtime/scripts/memory-report.sh
grep -Fq 'sys.boot_completed' runtime/scripts/wait-for-boot.sh
grep -Fq '[ -c /dev/binder ]' runtime/scripts/assert-runtime.sh
grep -Fq 'runtime-smoke-test' Makefile
grep -Fq 'SYS_ADMIN' runtime/security/experimental.env
grep -Fq 'privileged: false' runtime/compose.experimental.yaml
grep -Fq 'security-args.sh' runtime/scripts/smoke-test.sh
grep -Fq 'security-args.sh' runtime/scripts/multi-instance-test.sh
grep -Fq 'security-args.sh' runtime/scripts/memory-sweep.sh
grep -Fq 'runtime-security-contract-test' Makefile
grep -Fq 'runtime-security-sweep' Makefile
grep -Fq 'ROYD_SECURITY_MODES' runtime/scripts/security-sweep.sh
grep -Fq 'ROYD_SECURITY_MODE' runtime/.env.example
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

# External container integration code must not leak into royd. Prior art is credited only
# in the acknowledgement document, which is intentionally excluded from this scan.
grep -RniE 'remote-android|vendor_[A-Za-z0-9_-]*droid|device_[A-Za-z0-9_-]*droid|androidboot\.[A-Za-z0-9_-]*droid' \
  android runtime cli scripts docs README.md AGENTS.md \
  --exclude=acknowledgements.md --exclude=check-runtime.sh >/tmp/royd-forbidden-integrations.txt && {
    cat /tmp/royd-forbidden-integrations.txt >&2
    printf '%s\n' 'error: external Android container integration reference found outside acknowledgements' >&2
    exit 1
  }
rm -f /tmp/royd-forbidden-integrations.txt

# The software graphics baseline must stay explicit until a host path is implemented.
grep -Fq 'ro.hardware.egl=swiftshader' android/royd/vendor/royd/royd.mk || {
  printf '%s\n' 'error: royd software graphics baseline is not configured' >&2
  exit 1
}
grep -Fq 'vendor.royd.graphics.mode software' runtime/scripts/assert-runtime.sh || {
  printf '%s\n' 'error: runtime validation does not assert the graphics mode' >&2
  exit 1
}
