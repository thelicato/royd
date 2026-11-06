#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
source=${ROYD_ANDROID15_COMPOSER_SOURCE:-$root/android/graphics/composer-aidl4/composer/Composer.cpp}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
python3 - "$source" "$root/android/tests/fixtures/android15/ComposerVsyncContract.cpp" "$tmp/contract.cpp" <<'PY'
from pathlib import Path
import re, sys
source, fixture, output = map(Path, sys.argv[1:])
text = source.read_text(); result = fixture.read_text()
def function(pattern):
    match = re.search(pattern, text)
    assert match is not None, pattern
    opening = text.index('{', match.start()); depth = 1; end = opening + 1
    while depth:
        if text[end] == '{': depth += 1
        elif text[end] == '}': depth -= 1
        end += 1
    return text[match.start():end]
for marker, pattern in [
    ('CLOCK', r'int64_t ComposerClient::nowNanos\(\) const'),
    ('LOOP', r'void ComposerClient::vsyncLoop\(\)'),
    ('PROPERTY', r'int32_t propertyInt\('),
]:
    body = function(pattern)
    body = body.replace('std::chrono::steady_clock', 'FakeClock')
    body = body.replace('std::this_thread::sleep_for', 'sleepFor')
    body = body.replace('std::this_thread::sleep_until', 'sleepUntil')
    result = result.replace('// INSERT_ACTUAL_' + marker, body)
output.write_text(result)
PY
flags=
if [ "${ROYD_COMPOSER_VSYNC_CADENCE_ONLY:-0}" = 1 ]; then flags=-DCADENCE_ONLY; fi
# Word splitting is intentional for this fixed optional compiler flag.
# shellcheck disable=SC2086
c++ -std=c++17 -Wall -Wextra -Werror -pthread $flags "$tmp/contract.cpp" -o "$tmp/contract"
"$tmp/contract"
