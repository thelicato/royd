#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
tree=${ROYD_ANDROID_TEST_TREE:-$root/.work/android-src-15}
out=${1:?new output directory required}
jdk=$tree/prebuilts/jdk/jdk21/linux-x86
modules=${ROYD_ANDROID_TEST_SYSTEM_MODULES:-$tree/out/soong/.intermediates/libcore/core-all-system-modules/android_common/system}
framework=$tree/out/soong/.intermediates/frameworks/base/framework-minus-apex/android_common/turbine/framework.jar
connectivity=$tree/out/soong/.intermediates/packages/modules/Connectivity/framework-t/framework-connectivity-t.impl/android_common/turbine-combined/framework-connectivity-t.jar
sdk=$tree/prebuilts/sdk/current/public/android.jar
source=$root/runtime/tests/network-policy-usage/PolicyUsageProbe.java
for f in "$jdk/bin/javac" "$framework" "$connectivity" "$sdk" "$modules/lib/modules" "$tree/out/host/linux-x86/bin/d8"; do
 test -f "$f" || { printf 'error: policy usage build input missing: %s\n' "$f" >&2; exit 1; }
done
mkdir "$out"
out=$(CDPATH= cd -- "$out" && pwd)
mkdir "$out/classes" "$out/dex"
"$jdk/bin/javac" --system "$modules" -source 17 -target 17 -classpath "$framework:$connectivity:$sdk" -d "$out/classes" "$source"
"$jdk/bin/jar" --create --file "$out/probe.jar" -C "$out/classes" .
# Carry only the probe, using the running image's actual framework classes.
PATH="$jdk/bin:$PATH" "$tree/out/host/linux-x86/bin/d8" --min-api 35 --lib "$sdk" --output "$out/dex" "$out/probe.jar"
sha256sum "$source" "$framework" "$connectivity" "$modules/lib/modules" >"$out/compile-inputs.sha256"
