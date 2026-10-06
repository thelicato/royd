#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
vendor_init="$root/android/royd/vendor/royd/init.royd.rc"

[ -f "$vendor_init" ] || { echo 'missing royd vendor init configuration' >&2; exit 1; }

awk '
  $0 == "on post-fs-data && property:ro.build.version.sdk=35" {
    getline
    if ($0 == "    setprop sys.use_memfd true") found++
  }
  END { exit found == 1 ? 0 : 1 }
' "$vendor_init"

[ "$(grep -c '^    setprop sys.use_memfd true$' "$vendor_init")" -eq 1 ]
grep -F 'Stock Android resets this property to false during post-fs-data.' "$vendor_init" >/dev/null

if grep -Eq '^on post-fs-data$' "$vendor_init" &&
    awk '
      $0 == "on post-fs-data" { in_plain = 1; next }
      /^on / { in_plain = 0 }
      in_plain && $0 == "    setprop sys.use_memfd true" { found = 1 }
      END { exit found ? 0 : 1 }
    ' "$vendor_init"; then
  echo 'Android memfd override is not scoped to SDK 35' >&2
  exit 1
fi

printf '%s\n' 'Android 15 memfd container contract passed'
