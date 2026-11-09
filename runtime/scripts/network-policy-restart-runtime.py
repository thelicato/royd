#!/usr/bin/env python3
"""Wait for owned finite-policy observation/restoration, then run the full gate."""
from pathlib import Path
import json,os,sys,time
root=Path(__file__).resolve().parents[2]
out=Path(os.environ['ROYD_POLICY_RESTART_HOOK'])
if len(sys.argv)!=2 or sys.argv[1]!=os.environ['ROYD_POLICY_RESTART_CID']:
    raise ValueError('Policy restart runtime-hook ownership changed')
with (out/'ready.tmp').open('x') as f:
    json.dump(dict(cid=sys.argv[1],pid=os.getpid(),ready_ns=time.monotonic_ns()),f)
os.link(out/'ready.tmp',out/'ready.json');(out/'ready.tmp').unlink()
deadline=time.monotonic()+180
while not (out/'continue').exists():
    if time.monotonic()>=deadline:raise TimeoutError('Owned policy restoration hand-off timed out')
    time.sleep(.05)
if (out/'continue').read_text()!=sys.argv[1]+'\n':
    raise ValueError('Policy restart runtime continuation ownership changed')
runner=str(root/'runtime/scripts/assert-runtime.sh')
os.execv(runner,[runner,sys.argv[1]])
