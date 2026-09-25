#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
android_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

manifest_rel=$(sh -c '. "$1"; printf "%s" "${ANDROID_DEVICE_MANIFEST:-}"' sh "$android_dir/versions/15.env")
[ "$manifest_rel" = vintf/manifest-15.xml ] || fail "Android 15 device manifest metadata mismatch: $manifest_rel"
manifest="$android_dir/royd/device/royd/$manifest_rel"
[ -f "$manifest" ] || fail "Android 15 device manifest missing: $manifest"

python3 - "$manifest" <<'PY'
import sys
import xml.etree.ElementTree as ET

path = sys.argv[1]
root = ET.parse(path).getroot()
expected = {
    "version": "1.0",
    "type": "device",
    "target-level": "202404",
}
if root.tag != "manifest":
    raise SystemExit(f"error: {path} root element is {root.tag!r}, expected 'manifest'")
for key, value in expected.items():
    if root.get(key) != value:
        raise SystemExit(
            f"error: {path} {key}={root.get(key)!r}, expected {value!r}"
        )
hals = []
for hal in root.findall("hal"):
    name = hal.findtext("name")
    version = hal.findtext("version")
    interface = hal.find("interface")
    interface_name = interface.findtext("name") if interface is not None else None
    instance = interface.findtext("instance") if interface is not None else None
    hals.append((hal.get("format"), name, version, interface_name, instance))
expected_hals = [
    ("aidl", "android.hardware.graphics.allocator", "2", "IAllocator", "default"),
    ("native", "mapper", "5.0", None, "royd"),
    ("aidl", "android.hardware.graphics.composer3", "4", "IComposer", "default"),
]
if hals != expected_hals:
    raise SystemExit(f"error: {path} HAL declarations mismatch: {hals!r}")
PY

# Android 15 declares the modern graphics family it actually installs.
grep -Fq '<name>android.hardware.graphics.composer3</name>' "$manifest" || fail 'Android 15 manifest lacks composer3 AIDL declaration'
! grep -Fq '<name>android.hardware.graphics.composer</name>' "$manifest" || fail 'Android 15 manifest still declares legacy HIDL composer'
grep -Fq '<name>android.hardware.graphics.allocator</name>' "$manifest" || fail 'Android 15 manifest lacks allocator AIDL declaration'
grep -Fq '<name>mapper</name>' "$manifest" || fail 'Android 15 manifest lacks mapper native declaration'

grep -Fq 'PRODUCT_OTA_ENFORCE_VINTF_KERNEL_REQUIREMENTS := false' "$android_dir/compat/modern/product.mk" || \
  fail 'modern product family does not disable OTA kernel metadata enforcement'
! grep -R -Fq 'PRODUCT_ENFORCE_VINTF_MANIFEST := false' "$android_dir/compat" "$android_dir/royd" || \
  fail 'repository-owned Android product disables normal VINTF validation'

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM
mkdir -p "$work/build"
ROYD_ANDROID_VERSION=15 "$script_dir/install-royd.sh" "$work" standard >/dev/null
cmp "$manifest" "$work/device/royd/$manifest_rel"
grep -Fxq 'DEVICE_MANIFEST_FILE := device/royd/vintf/manifest-15.xml' "$work/device/royd/BoardConfigVersion.mk" || \
  fail 'Android 15 installed board fragment does not select the repository-owned device manifest'
grep -Fxq 'PRODUCT_OTA_ENFORCE_VINTF_KERNEL_REQUIREMENTS := false' "$work/device/royd/container_version.mk" || \
  fail 'Android 15 installed product does not retain the kernel-less OTA VINTF setting'
grep -Fxq 'SYSTEM_EXT_PRIVATE_SEPOLICY_DIRS += device/royd/sepolicy/system_ext/private' "$work/device/royd/BoardConfigVersion.mk" || \
  fail 'Android 15 installed board fragment does not include stable-C mapper service policy'
grep -Fxq 'mapper/royd    u:object_r:hal_graphics_mapper_service:s0' "$work/device/royd/sepolicy/system_ext/private/service_contexts" || \
  fail 'Android 15 mapper service context is missing'
grep -Fxq 'BOARD_VENDOR_SEPOLICY_DIRS += device/royd/sepolicy/vendor' "$work/device/royd/BoardConfigVersion.mk" || \
  fail 'Android 15 board fragment does not include composer3 vendor policy'
grep -Fq 'hal_graphics_composer_default_exec:s0' "$work/device/royd/sepolicy/vendor/file_contexts" || \
  fail 'Android 15 composer3 executable label is missing'
# The upstream AIDL Health module owns and installs its source V4
# device-manifest fragment. Stable-AIDL release handling emits frozen V3 for
# bp1a. Keep it out of the central manifest to avoid a duplicate declaration,
# but require the Android 15 product to install that module.
grep -Fxq 'PRODUCT_PACKAGES += android.hardware.health-service.example' "$work/vendor/royd/version.mk" || \
  fail 'Android 15 product does not install the module-owned AIDL Health VINTF fragment'

# Other configured versions must not silently inherit Android 15's target FCM.
rm -rf "$work/device/royd" "$work/vendor/royd"
ROYD_ANDROID_VERSION=14 "$script_dir/install-royd.sh" "$work" standard >/dev/null
! grep -Fq 'DEVICE_MANIFEST_FILE' "$work/device/royd/BoardConfigVersion.mk" || \
  fail 'Android 14 unexpectedly selected the Android 15 device manifest'
! grep -Fq 'ROYD_HEALTH_SERVICE :=' "$work/vendor/royd/version.mk" || \
  fail 'Android 14 unexpectedly selected Android 15 AIDL Health'

printf '%s\n' 'Android VINTF foundation contract test passed'
