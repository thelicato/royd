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
if list(root):
    raise SystemExit(
        f"error: {path} must remain a foundation manifest until real HAL declarations are implemented"
    )
PY

# Android 15 must not pretend the known-incompatible legacy composer satisfies
# the 202404 framework matrix. The modern graphics task owns future HAL entries.
! grep -Fq 'android.hardware.graphics.composer' "$manifest" || fail 'Android 15 foundation manifest declares a graphics composer prematurely'

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

# Other configured versions must not silently inherit Android 15's target FCM.
rm -rf "$work/device/royd" "$work/vendor/royd"
ROYD_ANDROID_VERSION=14 "$script_dir/install-royd.sh" "$work" standard >/dev/null
! grep -Fq 'DEVICE_MANIFEST_FILE' "$work/device/royd/BoardConfigVersion.mk" || \
  fail 'Android 14 unexpectedly selected the Android 15 device manifest'

printf '%s\n' 'Android VINTF foundation contract test passed'
