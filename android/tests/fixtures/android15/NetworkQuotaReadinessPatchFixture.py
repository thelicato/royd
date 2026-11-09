#!/usr/bin/env python3
"""Reconstruct shared policy context, then reverse owned prerequisite patches."""
from pathlib import Path
import subprocess,sys
from SettingsSearchPatchFixture import sources
patches=[Path(x).resolve() for x in sys.argv[1:]]
assert len(patches)==4
name='frameworks/base/services/core/java/com/android/server/net/NetworkPolicyManagerService.java'
target=Path(name)
if target.exists():
    text=target.read_text()
    assert all(x in text for x in ('private long roydInterfaceQuotaLimit(',
                                  'boolean roydAwaitingUsage = false;',
                                  'royd Ethernet quota readiness:')),'Partial readiness fixture'
    raise SystemExit(0)
rows=[]
for patch in patches:
    text=sources(patch,after=patch!=patches[-1],prefixes=('frameworks/base/',))[name]
    lines=text.splitlines();rows.extend(['']*max(0,len(lines)-len(rows)))
    for number,line in enumerate(lines):
        if line:
            assert not rows[number] or rows[number]==line,(patch.name,number)
            rows[number]=line
target.parent.mkdir(parents=True,exist_ok=True);target.write_text('\n'.join(rows)+'\n')
for patch in reversed(patches[:-1]):
    sections=patch.read_text().split('diff --git ')[1:]
    policy=[section for section in sections if section.splitlines()[0].endswith(' b/'+name)]
    assert len(policy)==1
    result=subprocess.run(['patch','--batch','--fuzz=0','-R','-p1'],input='diff --git '+policy[0],text=True,capture_output=True)
    assert result.returncode==0,(patch.name,result.stdout,result.stderr)
