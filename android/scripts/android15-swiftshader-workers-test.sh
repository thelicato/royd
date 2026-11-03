#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
python3 - "$root" "$tmp" "${ROYD_ANDROID15_SWIFTSHADER_SOURCE:-}" <<'PY'
from pathlib import Path
import sys
root, out = map(Path, sys.argv[1:3])
sys.dont_write_bytecode = True
sys.path.insert(0, str(root/'android/tests/fixtures/android15'))
from SettingsSearchPatchFixture import sources
patch = root/'android/patches/android-15.0.0_r36/0082-swiftshader-bound-low-memory-workers.patch'
old = sources(patch, prefixes=('external/swiftshader/',))
new = sources(patch, after=True, prefixes=('external/swiftshader/',))
path = 'external/swiftshader/src/System/SwiftConfig.cpp'
if sys.argv[3]:
    new[path] = (Path(sys.argv[3])/path).read_text()

def function(text, signature):
    assert text.count(signature) == 1
    begin = text.index(signature)
    end = text.index('{', begin) + 1
    depth = 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[begin:end]

signature = 'marl::Scheduler::Config getSchedulerConfiguration('
template = (root/'android/tests/fixtures/android15/SwiftShaderWorkerContract.cpp').read_text()
for marker, body in {
    '// INSERT_STOCK_CONFIGURATION': function(old[path], signature),
    '// INSERT_CONTAINER_GATE': function(new[path], 'bool isRoydLowMemoryContainer('),
    '// INSERT_PATCHED_CONFIGURATION': function(new[path], signature),
}.items():
    assert template.count(marker) == 1
    template = template.replace(marker, body)
assert new[path].count('#if defined(__ANDROID__) && defined(__x86_64__)') == 3
(out/'contract.cpp').write_text(template)
PY
cxx=${CXX:-c++}
for mode in stock-host android; do
  define=
  [ "$mode" != android ] || define=-D__ANDROID__
  "$cxx" -std=c++17 -O2 -Wall -Wextra -Werror -pthread $define "$tmp/contract.cpp" -o "$tmp/contract"
  "$tmp/contract"
done
printf '%s\n' 'Android 15 software Vulkan worker budget contracts passed'
