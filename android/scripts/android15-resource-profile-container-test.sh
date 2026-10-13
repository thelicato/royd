#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
patch="$root/android/patches/android-15.0.0_r36/0036-init-load-container-resource-profile.patch"

[ -f "$patch" ] || { echo 'missing Android 15 resource-profile patch' >&2; exit 1; }
[ "$(grep -c '^diff --git a/system/core/init/property_service.cpp' "$patch")" -eq 1 ]
[ "$(grep -c '^diff --git ' "$patch")" -eq 1 ]
grep -F 'const char* roydContainer = getenv("ROYD_CONTAINER");' "$patch" >/dev/null
grep -F "roydContainer[0] == '1' && roydContainer[1] == '\\0'" "$patch" >/dev/null
grep -F 'is_selinux_enabled() <= 0;' "$patch" >/dev/null
grep -F 'constexpr const char* kRoydResourceProp = "/royd-resource.prop";' "$patch" >/dev/null
grep -F 'load_properties_from_file(kRoydResourceProp, nullptr, &properties)' "$patch" >/dev/null
grep -F 'ROYD: loading container resource profile properties' "$patch" >/dev/null
grep -F 'LOG(FATAL) << res.error();' "$patch" >/dev/null

# The override is merged before Android publishes any boot properties. The exact royd and
# SELinux-disabled gate prevents a container resource file from changing normal Android boots.
load_line=$(grep -n 'load_properties_from_file(kRoydResourceProp' "$patch" | cut -d: -f1)
publish_line=$(grep -n '^     for (const auto& \[name, value\] : properties)' "$patch" | cut -d: -f1)
[ "$load_line" -lt "$publish_line" ] || {
  echo 'Android 15 resource profile is loaded after boot properties are published' >&2
  exit 1
}
if grep -Eq '^-.*(PropertySetNoSocket|load_properties_from_partition|kDebugRamdiskProp)' "$patch"; then
  echo 'Android 15 resource-profile patch changes the stock property-loading path' >&2
  exit 1
fi

printf '%s\n' 'Android 15 container resource profile contract passed'
