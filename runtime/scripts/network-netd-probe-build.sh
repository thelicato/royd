#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
tree=${ROYD_ANDROID_TEST_TREE:-$root/.work/android-src-15}
out=${1:?new output directory required}
source=${2:?Java probe source required}
test -f "$source"
jdk=$tree/prebuilts/jdk/jdk21/linux-x86
modules=${ROYD_ANDROID_TEST_SYSTEM_MODULES:-$tree/out/soong/.intermediates/libcore/core-all-system-modules/android_common/system}
framework=$tree/out/soong/.intermediates/frameworks/base/framework-minus-apex/android_common/turbine/framework.jar
aidl=$tree/out/soong/.intermediates/packages/modules/Connectivity/staticlibs/netd/netd_aidl_interface-V15-java/android_common/javac/netd_aidl_interface-V15-java.jar
sdk=$tree/prebuilts/sdk/current/public/android.jar
for file in "$jdk/bin/javac" "$framework" "$aidl" "$sdk" "$modules/lib/modules" "$tree/out/host/linux-x86/bin/d8"; do
 test -f "$file" || { printf 'error: netd test build input missing: %s\n' "$file" >&2; exit 1; }
done
mkdir "$out"
out=$(CDPATH= cd -- "$out" && pwd)
mkdir "$out/classes" "$out/dex"
"$jdk/bin/javac" --system "$modules" -source 17 -target 17 -classpath "$framework:$aidl:$sdk" \
 -d "$out/classes" "$source"
"$jdk/bin/jar" --create --file "$out/probe.jar" -C "$out/classes" .
# Carry only the generated stock AIDL client/listener, never framework stubs.
PATH="$jdk/bin:$PATH" "$tree/out/host/linux-x86/bin/d8" --min-api 35 --lib "$sdk" \
 --output "$out/dex" "$out/probe.jar" "$aidl"
sha256sum "$source" "$framework" "$aidl" "$modules/lib/modules" >"$out/compile-inputs.sha256"
