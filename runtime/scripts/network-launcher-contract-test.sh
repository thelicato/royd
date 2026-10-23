#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
for manifest in AndroidManifest.xml PolicyControlManifest.xml; do
  file="$root/runtime/tests/network-dns/$manifest"
  [ "$(grep -c 'MeteredProbeLauncher.*android:turnScreenOn="true"' "$file")" -eq 1 ]
  [ "$(grep -c 'MeteredProbeLauncher.*android:showWhenLocked="true"' "$file")" -eq 1 ]
  [ "$(grep -c '<uses-permission ' "$file")" -eq 2 ]
  ! grep -Eq 'WAKE_LOCK|FOREGROUND_SERVICE|sharedUserId' "$file"
done
source="$root/runtime/tests/network-dns/MeteredProbeLauncher.java"
! grep -Eq 'startForeground|PowerManager|WakeLock|Settings\.' "$source"
if [ -n "${ROYD_TEST_JAVA_HOME:-}" ]; then
  javac="$ROYD_TEST_JAVA_HOME/bin/javac"
  java="$ROYD_TEST_JAVA_HOME/bin/java"
else
  javac=javac
  java=java
fi
if ! command -v "$javac" >/dev/null 2>&1 || ! command -v "$java" >/dev/null 2>&1; then
  printf '%s\n' 'Launcher Java execution skipped: configure ROYD_TEST_JAVA_HOME'
  exit 0
fi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
# Keep the complete production class body; replace only Android type resolution with the harness.
sed '/^package /d; /^import /d' "$source" >"$tmp/MeteredProbeLauncher.java"
"$javac" --release 17 -d "$tmp" "$tmp/MeteredProbeLauncher.java" \
  "$root/runtime/tests/network-dns/launcher-harness/LauncherTest.java"
"$java" -cp "$tmp" LauncherTest
