#!/bin/sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
tree=${ROYD_ANDROID_TEST_TREE:-$root/.work/android-src-15}
out=${1:?usage: network-dns-build.sh NEW_OUTPUT_DIR}
jdk=$tree/prebuilts/jdk/jdk21/linux-x86
sdk=$tree/prebuilts/sdk/current/public/android.jar
for file in "$jdk/bin/javac" "$jdk/bin/java" "$sdk" "$tree/out/host/linux-x86/bin/aapt2" \
    "$tree/out/host/linux-x86/bin/d8" "$tree/out/host/linux-x86/framework/signapk.jar"; do
  [ -f "$file" ] || { printf 'error: Android test build prerequisite missing: %s\n' "$file" >&2; exit 1; }
done
mkdir "$out"
out=$(CDPATH= cd -- "$out" && pwd)
mkdir "$out/classes" "$out/dex"
if [ -n "${ROYD_ANDROID_TEST_SYSTEM_MODULES:-}" ]; then
  [ -f "$ROYD_ANDROID_TEST_SYSTEM_MODULES/lib/modules" ] || { printf 'error: Android test system modules missing: %s\n' "$ROYD_ANDROID_TEST_SYSTEM_MODULES" >&2; exit 1; }
  "$jdk/bin/javac" --system "$ROYD_ANDROID_TEST_SYSTEM_MODULES" -source 17 -target 17 -classpath "$sdk" -d "$out/classes" "$root"/runtime/tests/network-dns/*.java
else
  "$jdk/bin/javac" --release 17 -classpath "$sdk" -d "$out/classes" "$root"/runtime/tests/network-dns/*.java
fi
PATH="$jdk/bin:$PATH" "$tree/out/host/linux-x86/bin/d8" --min-api 35 --lib "$sdk" --output "$out/dex" "$out"/classes/org/royd/networkprobe/*.class
"$tree/out/host/linux-x86/bin/aapt2" link -I "$sdk" --manifest "$root/runtime/tests/network-dns/AndroidManifest.xml" -o "$out/unsigned.apk"
(cd "$out/dex" && zip -q "$out/unsigned.apk" classes.dex)
# AOSP's public test key, not the platform key; request no privileged/shared UID.
"$jdk/bin/java" -Djava.library.path="$tree/out/host/linux-x86/lib64" -jar "$tree/out/host/linux-x86/framework/signapk.jar" \
  "$tree/build/make/target/product/security/testkey.x509.pem" "$tree/build/make/target/product/security/testkey.pk8" \
  "$out/unsigned.apk" "$out/probe.apk"
if [ "${ROYD_NETWORK_DNS_POLICY:-0}" = 1 ]; then
  "$tree/out/host/linux-x86/bin/aapt2" link -I "$sdk" --manifest "$root/runtime/tests/network-dns/PolicyControlManifest.xml" -o "$out/unsigned-control.apk"
  (cd "$out/dex" && zip -q "$out/unsigned-control.apk" classes.dex)
  "$jdk/bin/java" -Djava.library.path="$tree/out/host/linux-x86/lib64" -jar "$tree/out/host/linux-x86/framework/signapk.jar" \
    "$tree/build/make/target/product/security/testkey.x509.pem" "$tree/build/make/target/product/security/testkey.pk8" \
    "$out/unsigned-control.apk" "$out/control.apk"
fi
go build -o "$out/dns-fixture" "$root/runtime/tests/network-dns/fixture.go" "$root/runtime/tests/network-dns/policy.go"
go build -o "$out/http-fixture" "$root/runtime/tests/network-http/server.go"
