#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
go test "$root/runtime/tests/network-history/assess.go" "$root/runtime/tests/network-history/assess_test.go"
sh -n "$root/runtime/scripts/network-history-test.sh" "$root/runtime/scripts/network-history-assert.sh" "$root/runtime/scripts/network-history-build.sh"
sh -n "$root/runtime/scripts/network-history-restart-test.sh" "$root/runtime/scripts/network-history-restart-phase.sh"
manifest=$root/runtime/tests/network-dns/AndroidManifest.xml
[ "$(grep -c '<uses-permission ' "$manifest")" -eq 2 ]
! grep -Eq 'PACKAGE_USAGE_STATS|READ_NETWORK_USAGE_HISTORY|sharedUserId' "$manifest"
grep -Fq '.queryDetailsForUid(ConnectivityManager.TYPE_WIFI, null, 0, end, queryUid)' "$root/runtime/tests/network-dns/UsageHistoryProbe.java"
grep -Fq 'catch (SecurityException denied)' "$root/runtime/tests/network-dns/UsageHistoryProbe.java"
printf '%s\n' 'Recorded UID history, malformed/raw-map exclusion and ordinary-UID access contracts passed'
