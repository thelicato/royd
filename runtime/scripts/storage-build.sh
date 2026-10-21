#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
tree=${ROYD_ANDROID_TEST_TREE:-$root/.work/android-src-15}
out=${1:?usage: storage-build.sh NEW_OUTPUT_DIR}
jdk=$tree/prebuilts/jdk/jdk21/linux-x86
sdk=$tree/prebuilts/sdk/current/public/android.jar
mkdir "$out"
out=$(CDPATH= cd -- "$out" && pwd)
mkdir "$out/classes" "$out/dex"
"$jdk/bin/javac" --release 17 -classpath "$sdk" -d "$out/classes" "$root/runtime/tests/storage/StorageProbe.java"
PATH="$jdk/bin:$PATH" "$tree/out/host/linux-x86/bin/d8" --min-api 35 --lib "$sdk" --output "$out/dex" "$out"/classes/org/royd/storageprobe/*.class
"$tree/out/host/linux-x86/bin/aapt2" link -I "$sdk" --manifest "$root/runtime/tests/storage/AndroidManifest.xml" -o "$out/unsigned.apk"
(cd "$out/dex" && zip -q "$out/unsigned.apk" classes.dex)
# Public AOSP test key, no platform/shared UID, custom trust or permissions.
"$jdk/bin/java" -Djava.library.path="$tree/out/host/linux-x86/lib64" -jar "$tree/out/host/linux-x86/framework/signapk.jar" \
  "$tree/build/make/target/product/security/testkey.x509.pem" "$tree/build/make/target/product/security/testkey.pk8" \
  "$out/unsigned.apk" "$out/probe.apk"
