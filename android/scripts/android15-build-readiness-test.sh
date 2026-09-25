#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
android_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

version_env="$android_dir/versions/15.env"
composer="$android_dir/graphics/composer-aidl4"
composer_bp="$composer/Android.bp"
composer_h="$composer/composer/Composer.h"
composer_cpp="$composer/composer/Composer.cpp"
composer_rc="$composer/composer/composer.rc"
allocator="$android_dir/graphics/allocator-aidl2"
allocator_rc="$allocator/allocator/android.hardware.graphics.allocator-service.royd.rc"
manifest="$android_dir/royd/device/royd/vintf/manifest-15.xml"
file_contexts="$android_dir/royd/device/royd/sepolicy/vendor/file_contexts"
mapper_contexts="$android_dir/royd/device/royd/sepolicy/system_ext/private/service_contexts"

[ -f "$version_env" ] || fail 'Android 15 version metadata is missing'
grep -Fxq 'AOSP_TAG=android-15.0.0_r36' "$version_env" || fail 'Android 15 AOSP tag drifted'
grep -Fxq 'ANDROID_RELEASE=bp1a' "$version_env" || fail 'Android 15 release configuration drifted'
grep -Fxq 'ANDROID_HEALTH_SERVICE=android.hardware.health-service.example' "$version_env" || fail 'Android 15 health service contract drifted'
grep -Fxq 'ANDROID_GRAPHICS_COMPOSER=aidl4-client' "$version_env" || fail 'Android 15 does not select the current composer3 source ABI'
grep -Fxq 'ANDROID_GRAPHICS_ALLOCATOR=aidl2-stablec5-memfd' "$version_env" || fail 'Android 15 allocator contract drifted'
grep -Fxq 'ANDROID_GRAPHICS_MAPPER=stablec5-royd' "$version_env" || fail 'Android 15 mapper contract drifted'
grep -Fxq 'ANDROID_SOFTWARE_EGL=angle' "$version_env" || fail 'Android 15 software EGL contract drifted'

# android-15.0.0_r36 defines composer3 V1-V3 as frozen and builds its latest
# composer3 NDK defaults against current V4. A service using those defaults must
# implement the current method surface even on release builds that fall back to
# the last frozen V3 wire contract.
grep -Fq 'defaults: ["android.hardware.graphics.composer3-ndk_shared"]' "$composer_bp" || \
  fail 'composer does not use the Android 15 current composer3 NDK defaults'
grep -Fq 'android.hardware.graphics.composer3-command-buffer' "$composer_bp" || \
  fail 'composer command-buffer helper dependency is missing'
for method in getMaxLayerPictureProfiles startHdcpNegotiation getLuts; do
  grep -Fq "$method(" "$composer_h" || fail "composer current V4 declaration missing: $method"
  grep -Fq "ComposerClient::$method(" "$composer_cpp" || fail "composer current V4 implementation missing: $method"
done
grep -Fq 'aidl/android/hardware/drm/HdcpLevels.h' "$composer_h" || fail 'composer current V4 HDCP type include is missing'
grep -Fq 'return unsupported();' "$composer_cpp" || fail 'composer does not retain explicit unsupported capability handling'

# The source manifest names current V4. Android 15 stable-AIDL release handling
# rewrites an unfrozen manifest version to the last frozen version when the
# release flag disables unfrozen AIDL, so the repository must not hard-code V3
# while linking the current V4-generated service interface.
python3 - "$manifest" <<'PY'
import sys
import xml.etree.ElementTree as ET

root = ET.parse(sys.argv[1]).getroot()
if root.get("target-level") != "202404":
    raise SystemExit("error: Android 15 device manifest target-level must remain 202404")
versions = {}
for hal in root.findall("hal"):
    name = hal.findtext("name")
    versions[name] = hal.findtext("version")
expected = {
    "android.hardware.graphics.allocator": "2",
    "mapper": "5.0",
    "android.hardware.graphics.composer3": "4",
}
for name, version in expected.items():
    if versions.get(name) != version:
        raise SystemExit(f"error: {name} source manifest version {versions.get(name)!r}, expected {version!r}")
PY
grep -Fq 'RELEASE_AIDL_USE_UNFROZEN' "$manifest" || fail 'composer manifest lacks stable-AIDL release rationale'
! grep -Fq '<name>android.hardware.graphics.composer</name>' "$manifest" || fail 'Android 15 still declares legacy HIDL composer'

# Module names, installed paths, init declarations, VINTF instances and SELinux
# labels must describe the same binaries and mapper suffix.
grep -Fq 'name: "android.hardware.graphics.composer3-service.royd"' "$composer_bp" || fail 'composer Soong module name mismatch'
grep -Fq 'relative_install_path: "hw"' "$composer_bp" || fail 'composer must install below vendor/bin/hw'
grep -Fq '/vendor/bin/hw/android.hardware.graphics.composer3-service.royd' "$composer_rc" || fail 'composer init path does not match Soong output'
grep -Fq 'interface aidl android.hardware.graphics.composer3.IComposer/default' "$composer_rc" || fail 'composer init interface declaration mismatch'
grep -Fq 'android\.hardware\.graphics\.composer3-service\.royd' "$file_contexts" || fail 'composer SELinux file label path mismatch'
grep -Fq 'hal_graphics_composer_default_exec:s0' "$file_contexts" || fail 'composer executable does not use the standard composer domain entrypoint'

grep -Fq 'name: "android.hardware.graphics.allocator-service.royd"' "$allocator/Android.bp" || fail 'allocator Soong module name mismatch'
grep -Fq 'stem: "android.hardware.graphics.allocator-service"' "$allocator/Android.bp" || fail 'allocator stem does not match canonical service path'
grep -Fq 'init_rc: ["allocator/android.hardware.graphics.allocator-service.royd.rc"]' "$allocator/Android.bp" || fail 'allocator init rc must have a royd-specific install basename'
grep -Fq '/vendor/bin/hw/android.hardware.graphics.allocator-service' "$allocator_rc" || fail 'allocator init path does not match Soong stem'
grep -Fxq 'mapper/royd    u:object_r:hal_graphics_mapper_service:s0' "$mapper_contexts" || fail 'mapper service-context instance mismatch'

# Exercise the installer against a mock AOSP root and verify package selection
# without mutating an Android source checkout.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM
mkdir -p "$work/build" "$work/external/minigbm" "$work/external/mesa3d"
ROYD_ANDROID_VERSION=15 "$script_dir/install-royd.sh" "$work" standard >/dev/null
[ -d "$work/vendor/royd/graphics_composer" ] || fail 'installer omitted the current composer source project'
grep -Fxq 'ROYD_GRAPHICS_COMPOSER := aidl4-client' "$work/vendor/royd/version.mk" || fail 'installed Android 15 composer selector mismatch'
grep -Fxq 'ROYD_ANDROID_VERSION := 15' "$work/vendor/royd/version.mk" || fail 'installed Android version selector mismatch'
grep -Fxq 'ROYD_HEALTH_SERVICE := android.hardware.health-service.example' "$work/vendor/royd/version.mk" || fail 'installed Android 15 health service selector mismatch'
grep -Fxq 'PRODUCT_PACKAGES += android.hardware.health-service.example' "$work/vendor/royd/version.mk" || fail 'installed Android 15 product omits the AIDL health service'
grep -Fxq 'ROYD_SOFTWARE_EGL := angle' "$work/vendor/royd/version.mk" || fail 'installed Android 15 EGL selector mismatch'
grep -Fxq 'ROYD_SOFTWARE_EGL := angle' "$work/vendor/royd/graphics_backend.mk" || fail 'installed graphics backend cannot see Android 15 EGL selector'
grep -Fxq 'ROYD_GRAPHICS_ALLOCATOR := aidl2-stablec5-memfd' "$work/vendor/royd/graphics_backend.mk" || fail 'installed graphics backend cannot see Android 15 allocator selector'
grep -Fxq 'ROYD_GRAPHICS_COMPOSER := aidl4-client' "$work/vendor/royd/graphics_backend.mk" || fail 'installed graphics backend cannot see Android 15 composer selector'
grep -Fq 'android.hardware.graphics.composer3-service.royd' "$work/vendor/royd/graphics_backend.mk" || fail 'installed software product omits composer3 service'
grep -Fq '$(SRC_TARGET_DIR)/product/angle_default.mk' "$work/vendor/royd/graphics_backend.mk" || fail 'installed Android 15 software product does not select ANGLE'
grep -Fq 'ro.hardware.vulkan=pastel' "$work/vendor/royd/graphics_backend.mk" || fail 'installed Android 15 software product does not select SwiftShader Vulkan'
grep -Fq 'vulkan.pastel' "$work/vendor/royd/graphics_backend.mk" || fail 'installed Android 15 software product does not package SwiftShader Vulkan'
grep -Fq 'ro.hardware.egl=swiftshader' "$work/vendor/royd/graphics_backend.mk" || fail 'software backend lost the non-Android-15 SwiftShader fallback'
[ -f "$work/vendor/royd/graphics_allocator/allocator/android.hardware.graphics.allocator-service.royd.rc" ] || fail 'installer lost the royd-specific allocator init rc'
[ ! -e "$work/vendor/royd/graphics_allocator/allocator/allocator.rc" ] || fail 'installer retained the colliding generic allocator.rc basename'
! grep -Fq 'android.hardware.graphics.composer@' "$work/vendor/royd/version.mk" || fail 'installed Android 15 version fragment still packages HIDL composer'
grep -Fxq 'DEVICE_MANIFEST_FILE := device/royd/vintf/manifest-15.xml' "$work/device/royd/BoardConfigVersion.mk" || fail 'installed board fragment does not select Android 15 manifest'
grep -Fxq 'PRODUCT_OTA_ENFORCE_VINTF_KERNEL_REQUIREMENTS := false' "$work/device/royd/container_version.mk" || fail 'kernel-less OTA VINTF setting was lost'
grep -Fxq 'PRODUCT_COMPRESSED_APEX := false' "$work/device/royd/container_version.mk" || fail 'Android 15 container product re-enabled compressed APEX'
! grep -Fq 'default_art_config.mk' "$work/device/royd/container_version.mk" || fail 'Android 15 product redundantly inherits default_art_config.mk'
! grep -R -Fq 'PRODUCT_ENFORCE_VINTF_MANIFEST := false' "$work/device/royd" "$work/vendor/royd" || fail 'normal VINTF validation is disabled'

printf '%s\n' 'Android 15 build-readiness contract test passed'
