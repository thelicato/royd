#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
software="$root/android/graphics/software.mk"

[ -f "$software" ] || { echo 'missing software graphics product fragment' >&2; exit 1; }
[ "$(grep -c '^PRODUCT_SYSTEM_PROPERTIES += service.sf.prime_shader_cache=false$' "$software")" -eq 1 ]
grep -F 'ifeq ($(ROYD_SOFTWARE_EGL),angle)' "$software" >/dev/null
grep -F '$(call inherit-product, $(SRC_TARGET_DIR)/product/angle_default.mk)' "$software" >/dev/null
grep -F 'PRODUCT_VENDOR_PROPERTIES += ro.hardware.vulkan=pastel' "$software" >/dev/null

# Only Android 15 currently selects ANGLE for the software backend. Keep eager priming unchanged
# for the legacy SwiftShader path and for the separate host-GPU product fragments.
angle_line=$(grep -n '^ifeq ($(ROYD_SOFTWARE_EGL),angle)$' "$software" | cut -d: -f1)
property_line=$(grep -n '^PRODUCT_SYSTEM_PROPERTIES += service.sf.prime_shader_cache=false$' "$software" | cut -d: -f1)
else_line=$(grep -n '^else$' "$software" | head -n 1 | cut -d: -f1)
[ "$angle_line" -lt "$property_line" ] && [ "$property_line" -lt "$else_line" ] || {
  echo 'software shader-cache override is not confined to the ANGLE branch' >&2
  exit 1
}
! grep -Fq 'prime_shader_cache' "$root/android/graphics/host-gpu-generic.mk"
! grep -Fq 'prime_shader_cache' "$root/android/graphics/host-gpu-intel.mk"

printf '%s\n' 'Android 15 software shader-cache policy passed'
