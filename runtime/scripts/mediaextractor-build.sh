#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
tree=${ROYD_ANDROID_TEST_TREE:-$root/.work/android-src-15}
out=${1:?usage: mediaextractor-build.sh NEW_OUTPUT_DIR}
jdk=$tree/prebuilts/jdk/jdk21/linux-x86
sdk=$tree/prebuilts/sdk/current/public/android.jar
mkdir "$out"
out=$(CDPATH= cd -- "$out" && pwd)
mkdir "$out/classes" "$out/dex" "$out/assets"
"$jdk/bin/javac" --release 17 -classpath "$sdk" -d "$out/classes" "$root/runtime/tests/mediaextractor/MediaProbe.java"
PATH="$jdk/bin:$PATH" "$tree/out/host/linux-x86/bin/d8" --min-api 35 --lib "$sdk" --output "$out/dex" "$out"/classes/org/royd/mediaprobe/*.class
"$tree/out/host/linux-x86/bin/aapt2" link -I "$sdk" --manifest "$root/runtime/tests/mediaextractor/AndroidManifest.xml" -o "$out/unsigned.apk"
python3 - "$out/assets/probe.wav" <<'PY'
import struct, sys, wave
with wave.open(sys.argv[1], 'wb') as output:
    output.setparams((1, 2, 8000, 0, 'NONE', 'not compressed'))
    output.writeframes(b''.join(struct.pack('<h', 8000 if i % 16 < 8 else -8000) for i in range(2000)))
PY
(cd "$out/dex" && zip -q "$out/unsigned.apk" classes.dex)
(cd "$out" && zip -0 -q "$out/unsigned.apk" assets/probe.wav)
"$jdk/bin/java" -Djava.library.path="$tree/out/host/linux-x86/lib64" -jar "$tree/out/host/linux-x86/framework/signapk.jar" \
  "$tree/build/make/target/product/security/testkey.x509.pem" "$tree/build/make/target/product/security/testkey.pk8" \
  "$out/unsigned.apk" "$out/probe.apk"
sha256sum "$out/assets/probe.wav" >"$out/fixture.sha256"
