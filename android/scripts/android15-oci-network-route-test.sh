#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
vendor_init="$root/android/royd/vendor/royd/init.royd.rc"
trigger='on property:sys.boot_completed=1 && property:ro.build.version.sdk=35'
command='    exec -- /system/bin/ip rule add pref 31999 lookup main'

[ -f "$vendor_init" ] || { echo 'missing royd vendor init configuration' >&2; exit 1; }

awk -v trigger="$trigger" -v command="$command" '
  $0 == trigger {
    getline
    if ($0 == command) found++
    next
  }
  index($0, "ip rule add") { unexpected++ }
  END { exit found == 1 && unexpected == 0 ? 0 : 1 }
' "$vendor_init"

[ "$(grep -Fxc "$command" "$vendor_init")" -eq 1 ]
grep -F 'Android policy routing ends with an unreachable rule' "$vendor_init" >/dev/null

# Netd reserves priority 32000 for its terminal unreachable rule. The fallback
# must remain immediately before it and after Android's normal priority-31000
# default-network rule so it cannot outrank Android-managed selections.
[ 31999 -gt 31000 ]
[ 31999 -lt 32000 ]

printf '%s\n' 'Android 15 OCI network route contract passed'
