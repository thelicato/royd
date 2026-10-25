#!/usr/bin/env python3
"""Compile pinned Minijail and execute the real policy in disposable children."""
from pathlib import Path
import os
import platform
import re
import subprocess
import sys

tree, temporary, policy = map(Path, sys.argv[1:])
root = Path(__file__).resolve().parents[2]
if sys.platform != 'linux' or platform.machine() != 'x86_64':
    raise SystemExit('Actual mediaextractor kernel policy test requires Linux x86_64')
stage = temporary / 'policies'
stage.mkdir()
sources = {
    'mediaextractor.policy': tree / 'frameworks/av/services/mediaextractor/seccomp_policy/mediaextractor-x86_64.policy',
    'crash_dump.x86_64.policy': tree / 'system/core/debuggerd/seccomp_policy/crash_dump.x86_64.policy',
    'code_coverage.x86_64.policy': tree / 'system/core/code_coverage/empty_policy/code_coverage.x86_64.policy',
    'royd.policy': policy,
}
for name, source in sources.items():
    text = source.read_text()
    def include(match):
        target = Path(match[1]).name
        assert target in sources, target
        return '@include ' + str(stage / target)
    text = re.sub(r'^@include (.+)$', include, text, flags=re.M)
    (stage / name).write_text(text)
# SetUpMinijail concatenates the base, optional vendor content and required
# addition before compilation. Keep the stock includes at their original depth.
(stage / 'combined.policy').write_text((stage / 'mediaextractor.policy').read_text()
                                     + '\n' + (stage / 'royd.policy').read_text())
mini = tree / 'external/minijail'
sources = [root / 'android/tests/mediaextractor-policy.c'] + [mini / name for name in (
    'syscall_filter.c', 'bpf.c', 'landlock_util.c', 'util.c',
    'linux-x86/libconstants.gen.c', 'linux-x86/libsyscalls.gen.c')]
binary = temporary / 'kernel-policy'
subprocess.run([os.environ.get('CC', 'cc'), '-std=gnu11', '-O2', '-D__ANDROID__', '-I' + str(mini),
                '-o', str(binary), *map(str, sources)], check=True)
subprocess.run([str(binary), str(stage / 'combined.policy')], check=True)
stubs = temporary / 'loader-stubs'
for name in ('android-base/file.h', 'android-base/logging.h', 'android-base/unique_fd.h',
             'libminijail.h', 'scoped_minijail.h'):
    path = stubs / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text('#pragma once\n')
loader = tree / 'frameworks/av/media/module/minijail/minijail.cpp'
binary = temporary / 'loader'
subprocess.run([os.environ.get('CXX', 'c++'), '-std=c++17', '-Wall', '-Wextra', '-Werror',
                '-I' + str(stubs), '-DROYD_LOADER_SOURCE="' + str(loader) + '"',
                str(root / 'android/tests/mediaextractor-loader.cpp'), '-o', str(binary)], check=True)
subprocess.run([str(binary)], check=True)
print('Actual applied policy loader: stock/vendor composition, required read/permission and pipe failures passed')
