#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
export PYTHONDONTWRITEBYTECODE=1
sh -n "$root/runtime/scripts/network-policy-usage-test.sh" "$root/runtime/scripts/network-policy-usage-build.sh" \
 "$root/runtime/scripts/network-policy-limit-test.sh" "$root/runtime/scripts/network-policy-continuity-test.sh" \
 "$root/runtime/scripts/network-policy-restart-test.sh" "$root/runtime/scripts/network-policy-concurrent-test.sh"
python3 -m unittest discover -s "$root/runtime/tests/network-policy-usage" -p '*_test.py'
tree=${ROYD_QUOTA_TEST_ANDROID_TREE:-}
if [ -z "$tree" ] && [ -f "$root/.work/android-src-15/out/host/linux-x86/bin/d8" ]; then tree=$root/.work/android-src-15; fi
if [ -n "$tree" ]; then
 tmp=$(mktemp -d)
 trap 'rm -rf "$tmp"' EXIT HUP INT TERM
 ROYD_ANDROID_TEST_TREE="$tree" "$root/runtime/scripts/network-policy-usage-build.sh" "$tmp/policy"
 printf '%s\n' 'Policy usage probe compiled against actual Android core/framework/connectivity classes'
fi
printf '%s\n' 'OCI network-policy usage contracts passed'
(
 tmp_burst=$(mktemp -d)
 trap 'rm -rf "$tmp_burst"' EXIT HUP INT TERM
 CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -o "$tmp_burst/burst" "$root/runtime/tests/network-policy-usage/burst.go"
 printf '%s\n' 'Bounded native continuity client compilation passed'
)
