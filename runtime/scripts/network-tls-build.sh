#!/bin/sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
tree=${ROYD_ANDROID_TEST_TREE:-$root/.work/android-src-15}
out=${1:?usage: network-tls-build.sh NEW_OUTPUT_DIR}
jdk=$tree/prebuilts/jdk/jdk21/linux-x86
sdk=$tree/prebuilts/sdk/current/public/android.jar
for file in "$jdk/bin/javac" "$jdk/bin/java" "$sdk" "$tree/out/host/linux-x86/bin/aapt2" \
    "$tree/out/host/linux-x86/bin/d8" "$tree/out/host/linux-x86/framework/signapk.jar"; do
  [ -f "$file" ] || { printf 'error: Android test build prerequisite missing: %s\n' "$file" >&2; exit 1; }
done
mkdir "$out"
out=$(CDPATH= cd -- "$out" && pwd)
mkdir "$out/classes" "$out/dex"
"$jdk/bin/javac" --release 17 -classpath "$sdk" -d "$out/classes" "$root/runtime/tests/network-tls/TlsProbe.java"
PATH="$jdk/bin:$PATH" "$tree/out/host/linux-x86/bin/d8" --min-api 35 --lib "$sdk" --output "$out/dex" "$out"/classes/org/royd/tlsprobe/*.class
"$tree/out/host/linux-x86/bin/aapt2" link -I "$sdk" --manifest "$root/runtime/tests/network-tls/AndroidManifest.xml" -o "$out/unsigned.apk"
(cd "$out/dex" && zip -q "$out/unsigned.apk" classes.dex)
# Public AOSP test key only, never the platform key or a privileged/shared UID.
"$jdk/bin/java" -Djava.library.path="$tree/out/host/linux-x86/lib64" -jar "$tree/out/host/linux-x86/framework/signapk.jar" \
  "$tree/build/make/target/product/security/testkey.x509.pem" "$tree/build/make/target/product/security/testkey.pk8" \
  "$out/unsigned.apk" "$out/probe.apk"
go build -o "$out/tls-fixture" "$root/runtime/tests/network-tls/probe.go"
