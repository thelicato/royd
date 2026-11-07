#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
python3 - "$root" "$tmp" "${ROYD_ANDROID15_VULKAN_SOURCE:-}" <<'PY'
from pathlib import Path
import sys
root, out = map(Path, sys.argv[1:3])
sys.dont_write_bytecode = True
sys.path.insert(0, str(root/'android/tests/fixtures/android15'))
from SettingsSearchPatchFixture import sources
patch = root/'android/patches/android-15.0.0_r36/0085-vulkan-consume-software-present-waits.patch'
old = sources(patch, prefixes=('frameworks/native/',))
new = sources(patch, after=True, prefixes=('frameworks/native/',))
path = 'frameworks/native/vulkan/libvulkan/swapchain.cpp'
if sys.argv[3]:
    new[path] = (Path(sys.argv[3])/path).read_text()

def function(text, signature):
    assert text.count(signature) == 1, signature
    begin = text.index(signature)
    end = text.index('{', begin) + 1
    depth = 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[begin:end]

template = (root/'android/tests/fixtures/android15/VulkanPresentContract.cpp').read_text()
for marker, body in {
    '// INSERT_STOCK_PRESENT': function(old[path], 'VkResult QueuePresentKHR('),
    '// INSERT_CONTAINER_GATE': function(new[path], 'static bool UseRoydSoftwarePresentWait('),
    '// INSERT_PATCHED_PRESENT': function(new[path], 'VkResult QueuePresentKHR('),
}.items():
    assert template.count(marker) == 1
    template = template.replace(marker, body)
(out/'contract.cpp').write_text(template)
PY
for mode in x86_64 other-architecture; do
  define=
  [ "$mode" != other-architecture ] || define=-DROYD_TEST_NON_X86
  "${CXX:-c++}" -std=c++17 -O2 -Wall -Wextra -Werror $define "$tmp/contract.cpp" -o "$tmp/contract"
  "$tmp/contract"
done
