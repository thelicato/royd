#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
tree=${ROYD_ANDROID_TEST_TREE:-$root/.work/android-src-15}
out=${1:?usage: vulkan-present-build.sh NEW_OUTPUT_DIR}
compiler=$tree/prebuilts/clang/host/linux-x86/clang-r530567b/bin/clang
resource=$tree/prebuilts/clang/host/linux-x86/clang-r530567b/lib/clang/19/include
product=$tree/out/target/product/royd_x86_64
crt=$tree/out/soong/.intermediates/bionic/libc
for file in "$compiler" "$crt/crtbegin_dynamic/android_x86_64/crtbegin_dynamic.o" \
    "$crt/crtend_android/android_x86_64/crtend_android.o" "$product/system/lib64/libvulkan.so" \
    "$product/system/lib64/libnativewindow.so" "$product/system/lib64/libmediandk.so" \
    "$product/system/lib64/bootstrap/libc.so" "$product/system/lib64/bootstrap/libdl.so"; do
  [ -f "$file" ] || { printf 'error: Android 15 native probe prerequisite missing: %s\n' "$file" >&2; exit 1; }
done
mkdir "$out"
out=$(CDPATH= cd -- "$out" && pwd)
# Use only the pinned Android compiler, headers, startup objects and platform libraries.
set -- "$compiler" --target=x86_64-linux-android35 -std=c11 -DVK_USE_PLATFORM_ANDROID_KHR \
  -O2 -g -Wall -Wextra -Werror -nostdlib -nostdinc -isystem "$resource" \
  -fuse-ld=lld -fPIE -pie -Wl,-dynamic-linker,/system/bin/linker64
for include in bionic/libc/include bionic/libc/arch-x86_64/include bionic/libc/kernel/uapi \
    bionic/libc/kernel/uapi/asm-x86 bionic/libc/kernel/android/uapi \
    frameworks/native/libs/nativewindow/include frameworks/native/libs/arect/include \
    external/vulkan-headers/include \
    frameworks/av/media/ndk/include; do
  set -- "$@" -isystem "$tree/$include"
done
"$@" "$crt/crtbegin_dynamic/android_x86_64/crtbegin_dynamic.o" \
  "$root/runtime/tests/vulkan-present/probe.c" \
  -L"$product/system/lib64" -L"$product/system/lib64/bootstrap" \
  -lc -lnativewindow -lvulkan -lmediandk \
  "$crt/crtend_android/android_x86_64/crtend_android.o" -o "$out/probe"
sha256sum "$root/runtime/tests/vulkan-present/probe.c" "$out/probe" >"$out/checksums.sha256"
printf 'Android 15 Vulkan presentation probe built: %s/probe\n' "$out"
