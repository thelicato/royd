#!/usr/bin/env python3
"""Reconstruct the shared preimage of the registration and dispatch patches."""
from pathlib import Path
import subprocess
import sys
from SettingsSearchPatchFixture import sources

predecessor, dispatch = (Path(x).resolve() for x in sys.argv[1:])
prefix = ('frameworks/base/services/core/java/com/android/server/net/',)
after_registration = sources(predecessor, after=True, prefixes=prefix)
before_dispatch = sources(dispatch, prefixes=prefix)
assert set(after_registration) == set(before_dispatch) and len(before_dispatch) == 1
for name in before_dispatch:
    target = Path(name)
    if target.exists():
        continue
    rows = []
    # The predecessor's postimage and successor's preimage share line coordinates.
    # Empty placeholders are not source; overlapping non-empty context must agree.
    for text in (after_registration[name], before_dispatch[name]):
        lines = text.splitlines()
        rows.extend([''] * max(0, len(lines)-len(rows)))
        for number, line in enumerate(lines):
            if line:
                assert not rows[number] or rows[number] == line, (name, number)
                rows[number] = line
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text('\n'.join(rows)+'\n')
    subprocess.run(['patch', '--batch', '--fuzz=0', '-R', '-p1', '-i', str(predecessor)],
                   check=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
