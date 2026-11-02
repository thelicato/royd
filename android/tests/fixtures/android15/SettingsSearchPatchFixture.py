#!/usr/bin/env python3
"""Reconstruct patch context for the sync fixture and executable Java contracts."""
from pathlib import Path
import re
import sys


def sources(patch, after=False):
    files = {}
    for section in Path(patch).read_text().split('diff --git ')[1:]:
        header, *lines = section.splitlines()
        path = header.split(' b/', 1)[1]
        assert path.startswith('packages/apps/Settings/') and '..' not in Path(path).parts
        rows = {}
        old = new = None
        for line in lines:
            match = re.match(r'@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@', line)
            if match:
                old, new = map(int, match.groups())
                continue
            if old is None or line.startswith('\\'):
                continue
            if not line:
                line = ' '
            if line[0] not in ' +-':
                continue
            kind, value = line[0], line[1:]
            if kind == ' ' or kind == ('+' if after else '-'):
                number = new if after else old
                assert number not in rows or rows[number] == value
                rows[number] = value
            if kind in ' -':
                old += 1
            if kind in ' +':
                new += 1
        files[path] = '\n'.join(rows.get(n, '') for n in range(1, max(rows) + 1)) + '\n'
    return files


def method(source, name):
    pattern = (r'(?m)^[ \t]*(?:(?:public|private|protected|static|final)\s+)*'
               r'(?:[\w<>,.\[\] ?]+[ \t]+)?' + re.escape(name) + r'\s*\([^;{]*\)\s*\{')
    matches = list(re.finditer(pattern, source))
    assert len(matches) == 1, (name, len(matches))
    start = matches[0].start()
    brace = source.index('{', matches[0].start())
    depth = 1
    end = brace + 1
    while depth:
        assert end < len(source), name
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


if __name__ == '__main__':
    for name, text in sources(sys.argv[1]).items():
        path = Path(name)
        if not path.exists():
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
