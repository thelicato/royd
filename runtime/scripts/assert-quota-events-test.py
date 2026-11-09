"""Reject missing, faulted or contradictory observer state with exact uint64 bounds."""
from pathlib import Path
import subprocess

script=Path(__file__).with_name('assert-quota-events.awk')
def line(generation='1',bytes='9223372036854775807',armed='yes',started='yes',committed='0',error='0'):
    return f'royd quota events: generation={generation} bytes={bytes} armed={armed} started={started} committed={committed} error={error} sample_ms=250\n'
good=[line(),line(generation='0',bytes='0',armed='no',started='no'),
      line(generation='0',bytes='0',armed='no'),line(bytes='0',armed='no'),
      line(armed='no',committed='1'),line(generation='18446744073709551615',committed='18446744073709551615')]
bad=[line(error='5'),line(generation='0'),line(armed='maybe'),line(started='no'),
     line(bytes='0'),line(armed='no'),line(generation='01'),line(bytes='9223372036854775808'),
     line(generation='18446744073709551616'),line(committed='18446744073709551616'),
     line()+line(),'missing\n',line().replace('sample_ms=250','sample_ms=0'),
     line().replace(' bytes=',' other='),line().rstrip()+' extra\n']
for expected,values in [(True,good),(False,bad)]:
    for witness in values:
        result=subprocess.run(['awk','-f',str(script)],input=witness,text=True,capture_output=True)
        assert (result.returncode==0)==expected,witness
        if expected:assert result.stdout==('unused\n' if 'generation=0 ' in witness else 'used\n')
print('Quota-event unused/active/committed, fault, duplicate and exact integer state contracts passed')
