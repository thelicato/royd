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

grep -Fq 'ROYD_DEFAULT_ANDROID_VERSION=15' android/baseline.env
for version in 8.0 8.1 9 10 11 12 13 14 15 16 17; do
  test -f "android/versions/$version.env"
done
grep -Fq 'AOSP_TAG=android-8.1.0_r81' android/versions/8.1.env
grep -Fq 'AOSP_TAG=android-9.0.0_r61' android/versions/9.env
grep -Fq 'AOSP_TAG=android-10.0.0_r47' android/versions/10.env
grep -Fq 'AOSP_TAG=android-11.0.0_r48' android/versions/11.env
grep -Fq 'AOSP_TAG=android-12.0.0_r34' android/versions/12.env
grep -Fq 'AOSP_TAG=android-13.0.0_r75' android/versions/13.env
grep -Fq 'AOSP_TAG=android-14.0.0_r14' android/versions/14.env
grep -Fq 'AOSP_TAG=android-15.0.0_r36' android/versions/15.env
grep -Fq 'AOSP_TAG=android-16.0.0_r4' android/versions/16.env
grep -Fq 'AOSP_TAG=android-17.0.0_r1' android/versions/17.env
grep -Fq 'ANDROID_BUILDER_FAMILY=legacy' android/versions/8.1.env
grep -Fq 'ANDROID_PRODUCT_FAMILY=legacy' android/versions/9.env
grep -Fq 'ANDROID_PRODUCT_FAMILY=transitional' android/versions/10.env
grep -Fq 'ANDROID_PRODUCT_FAMILY=modern' android/versions/11.env
test -f android/builder/Dockerfile.legacy
test -f android/compat/legacy/product.mk
test -f android/compat/transitional/product.mk
test -f android/compat/modern/product.mk
grep -Fq 'Android builder family and TTY tests passed' android/scripts/builder-family-test.sh
grep -Fq 'ANDROID_PRODUCT_X86_64=royd_x86_64' android/baseline.env
grep -Fq 'ANDROID_PRODUCT_ARM64=royd_arm64' android/baseline.env
grep -Fq 'royd_x86_64.mk' android/royd/device/royd/AndroidProducts.mk
grep -Fq 'royd_arm64.mk' android/royd/device/royd/AndroidProducts.mk
grep -Fq 'Android version matrix test passed' android/scripts/version-test.sh
grep -Fq 'Android graphics contract test passed' android/scripts/graphics-contract-test.sh
grep -Fq 'name: "gralloc.royd"' android/royd/vendor/royd/Android.bp
grep -Fq 'ro.hardware.gralloc=royd' android/graphics/software.mk
grep -Fq 'ro.hardware.egl=mesa' android/graphics/host-gpu-generic.mk
grep -Fq 'gralloc.minigbm_intel' android/graphics/host-gpu-intel.mk
grep -Fq 'Android graphics backend test passed' android/scripts/graphics-backend-test.sh
grep -Fq 'Runtime GPU contract test passed' runtime/scripts/gpu-contract-test.sh
grep -Fq 'android-build-host-gpu-arm64' Makefile
! grep -Fq 'renderD128' runtime/scripts/host-check.sh android/royd/vendor/royd/bin/royd-binder-setup android/royd/vendor/royd/bin/royd-hardware-setup
grep -Fq 'runtime-graphics-report' Makefile
grep -Fq 'android-version-test' Makefile
grep -Fq 'vendor/royd/royd.mk' android/royd/device/royd/royd_x86_64.mk
grep -Fq 'device/royd/container_common.mk' android/royd/device/royd/royd_x86_64.mk
grep -Fq 'device/royd/container_common.mk' android/royd/device/royd/royd_arm64.mk
grep -Fq 'container_version.mk' android/royd/device/royd/container_common.mk
grep -Fq 'generic_system.mk' android/compat/modern/product.mk
grep -Fq 'full_base.mk' android/compat/legacy/product.mk
grep -Fq 'aosp_product.mk' android/compat/transitional/product.mk
grep -Fq 'base_vendor.mk' android/compat/modern/product.mk
grep -Fq 'TARGET_NO_KERNEL := true' android/royd/device/royd/royd_x86_64/BoardConfig.mk
grep -Fq 'TARGET_ARCH := x86_64' android/royd/device/royd/royd_x86_64/BoardConfig.mk
grep -Fq 'TARGET_NO_KERNEL := true' android/royd/device/royd/royd_arm64/BoardConfig.mk
grep -Fq 'TARGET_ARCH := arm64' android/royd/device/royd/royd_arm64/BoardConfig.mk
grep -Fq 'BoardConfigVersion.mk' android/royd/device/royd/royd_x86_64/BoardConfig.mk
grep -Fq 'BoardConfigVersion.mk' android/royd/device/royd/royd_arm64/BoardConfig.mk
grep -Fq 'PRODUCT_USE_DYNAMIC_PARTITION_SIZE := true' android/compat/modern/product.mk
grep -Fq 'TARGET_NO_KERNEL=true' android/build-contract.env
grep -Fq 'BOARD_VENDORIMAGE_FILE_SYSTEM_TYPE=ext4' android/build-contract.env
grep -Fq 'get_build_var' android/scripts/config-check.sh
grep -Fq 'Android build contract checks passed' android/scripts/config-check.sh
grep -Fq 'ANDROID_REQUIRED_PARTITIONS' android/scripts/package.sh
grep -Fq 'ANDROID_OPTIONAL_PARTITIONS' android/scripts/package.sh
grep -Fq 'android-config-check' Makefile
grep -Fq 'android-config-check-test' Makefile
grep -Fq 'Android resolved build contract test passed' android/scripts/config-check-test.sh
grep -Fq 'android-build-matrix' Makefile
grep -Fq 'android-build-results-report' Makefile
grep -Fq 'RESULT_STATUS' android/scripts/build-matrix.sh
grep -Fq 'ROYD_BUILD_RESUME' android/scripts/build-matrix.sh
grep -Fq 'ROYD_CLEAN_BUILD' android/scripts/build.sh
grep -Fq 'ROYD_BUILDER_TTY' android/scripts/builder.sh
grep -Fq 'Build `pass` is recorded only by the clean-build matrix runner' android/scripts/matrix-report.sh
grep -Fq 'android-contract-test' Makefile
! grep -Fq 'aosp_x86_64.mk' android/royd/device/royd/royd_x86_64.mk
! grep -Fq 'aosp_arm64.mk' android/royd/device/royd/royd_arm64.mk
! grep -Fq 'emulator_vendor.mk' android/royd/device/royd/royd_x86_64.mk
! grep -Fq 'emulator_vendor.mk' android/royd/device/royd/royd_arm64.mk
! grep -R -Fq 'board/generic_x86_64/device.mk' android/royd/device/royd
! grep -R -Fq 'board/generic_arm64/device.mk' android/royd/device/royd
grep -Fq 'royd-binder-alloc' android/royd/vendor/royd/Android.bp
grep -Fq 'royd-binder-info' android/royd/vendor/royd/Android.bp
grep -Fq 'binder_info/royd-binder-info.c' android/royd/vendor/royd/Android.bp
grep -Fq 'royd-binder-info' android/royd/vendor/royd/royd.mk
grep -Fq 'BINDER_CTL_ADD' android/royd/vendor/royd/binder_alloc/royd-binder-alloc.c
grep -Fq '/vendor/bin/royd-binder-alloc' android/royd/vendor/royd/bin/royd-binder-setup
grep -Fq 'exec -- /vendor/bin/royd-binder-setup' android/royd/vendor/royd/init.royd.rc
grep -Fq 'on property:init.svc.logd=running' android/royd/vendor/royd/init.royd.rc
grep -Fq 'setprop service.adb.tcp.port 5555' android/royd/vendor/royd/init.royd.rc
grep -Fq 'start adbd' android/royd/vendor/royd/init.royd.rc
grep -Fq 'royd-health' android/royd/vendor/royd/royd.mk
grep -Fq 'PRODUCT_DEFAULT_PROPERTY_OVERRIDES += ro.adb.secure=0' android/compat/legacy/vendor.mk
grep -Fq 'PRODUCT_DEFAULT_PROPERTY_OVERRIDES += ro.adb.secure=0' android/compat/transitional/vendor.mk
grep -Fq 'PRODUCT_SYSTEM_DEFAULT_PROPERTIES += ro.adb.secure=0' android/compat/modern/vendor.mk
grep -Fq 'HEALTHCHECK --interval=10s' runtime/scripts/import.sh
grep -Fq 'EXPOSE 5555/tcp' runtime/scripts/import.sh
grep -Fq 'init.svc.adbd running' runtime/scripts/assert-runtime.sh
grep -Fq 'runtime-adb-check' Makefile
grep -Fq 'runtime-adb-contract-test' Makefile
grep -Fq 'runtime-status' Makefile
grep -Fq '/proc/1/fd/1' android/royd/vendor/royd/bin/royd-logcat
grep -Fq 'exec -- /vendor/bin/royd-display-bootstrap' android/royd/vendor/royd/init.royd.rc
grep -Fq 'name: "royd-display-bootstrap"' android/royd/vendor/royd/Android.bp
grep -Fq 'vendor.royd.display.width' android/royd/vendor/royd/gralloc/gralloc_royd.cpp
! test -e android/royd/vendor/royd/bin/royd-display-setup
grep -Fq 'ro.config.low_ram=true' android/compat/modern/vendor.mk
grep -Fq 'ro.config.low_ram=true' android/compat/legacy/vendor.mk
grep -Fq 'ro.lmk.use_psi=true' android/compat/modern/vendor.mk
grep -Fq 'ro.lmk.use_minfree_levels=false' android/compat/modern/vendor.mk
grep -Fq 'ENTRYPOINT ["/royd-entrypoint"]' runtime/scripts/import.sh
grep -Fq 'royd.width=540' runtime/scripts/import.sh
grep -Fq 'royd.height=960' runtime/scripts/import.sh
grep -Fq 'exec /init' runtime/rootfs/royd-entrypoint
! grep -R -Fq 'androidboot.royd_' runtime cli android/royd/vendor/royd docs README.md AGENTS.md
! grep -Fq 'androidboot.hardware=royd' runtime/scripts/import.sh
grep -Fq 'org.opencontainers.image.title=royd' runtime/scripts/import.sh
grep -Fq 'org.royd.image-format' runtime/scripts/import.sh
grep -Fq 'ARCHIVE_SHA256' android/scripts/package.sh
grep -Fq 'ROYD_IMAGE_FORMAT=2' runtime/image.env
grep -Fq 'royd:15.0.0-r36-standard-graphical-amd64' runtime/scripts/image-contract-test.sh
grep -Fq 'royd:14.0.0-r14-standard-graphical-amd64' runtime/scripts/image-contract-test.sh
grep -Fq 'royd:16.0.0-r4-minimal-graphical-arm64' runtime/scripts/image-contract-test.sh
grep -Fq 'royd:17.0.0-r1-standard-graphical-amd64' runtime/scripts/image-contract-test.sh
grep -Fq '/royd-release' runtime/scripts/image-inspect.sh
grep -Fq 'runtime-image-contract-test' Makefile
grep -Fq 'runtime-entrypoint-contract-test' Makefile
grep -Fq 'android-display-contract-test' Makefile
grep -Fq 'android-hal-profile-test' Makefile
grep -Fq 'android-hal-contract-test' Makefile
grep -Fq 'ro.vendor.royd.hal_profile=headless' android/hal-profiles/headless.mk
grep -Fq 'ro.vendor.royd.hal_profile=graphical' android/hal-profiles/graphical.mk
grep -Fq 'vendor/royd/hal_profile.mk' android/royd/vendor/royd/royd.mk
grep -Fq 'ROYD_HAL_PROFILE' android/scripts/package.sh
grep -Fq 'org.royd.hal-profile' runtime/scripts/import.sh
grep -Fq 'runtime-smoke-test-headless' Makefile
grep -Fq 'royd.width=' runtime/scripts/profile.sh
grep -Fq 'royd.width=' runtime/compose.yaml
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
grep -Fq 'runtime-binder-isolation-test' Makefile
grep -Fq 'runtime-qualification' Makefile
grep -Fq 'runtime-qualification-report' Makefile
grep -Fq 'runtime-qualification-contract-test' Makefile
grep -Fq 'runtime-qualification-matrix' Makefile
grep -Fq 'runtime-qualification-matrix-test' Makefile
grep -Fq 'ROYD_QUALIFY_RESUME' runtime/scripts/qualification-matrix.sh
grep -Fq 'Runtime qualification matrix test passed' runtime/scripts/qualification-matrix-test.sh
grep -Fq 'BINDER_ISOLATION_STATUS' runtime/scripts/qualification.sh
grep -Fq 'ROYD_MATRIX_REQUIRE_RUNTIME' android/scripts/matrix-report.sh
grep -Fq 'runtime-qualified' android/scripts/matrix-report.sh
grep -Fq 'ROYD_WIDTH=64' runtime/profiles/headless.env
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
grep -Fq 'default-image.sh' runtime/scripts/reference-report.sh
grep -Fq 'default-image.sh' runtime/scripts/smoke-test.sh
grep -Fq 'default-image.sh' runtime/scripts/memory-sweep.sh
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

# Software remains the default while host GPU paths stay explicit and experimental.
grep -Fq 'ro.hardware.egl=swiftshader' android/graphics/software.mk || {
  printf '%s\n' 'error: royd software graphics baseline is not configured' >&2
  exit 1
}
grep -Fq 'host-gpu-generic' android/scripts/graphics-backend.sh || {
  printf '%s\n' 'error: host GPU graphics backend contract is missing' >&2
  exit 1
}
grep -Fq 'graphics_mode=host-gpu' runtime/scripts/assert-runtime.sh || {
  printf '%s\n' 'error: runtime validation does not assert host GPU mode' >&2
  exit 1
}
