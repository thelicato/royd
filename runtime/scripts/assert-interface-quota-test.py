"""Reject unavailable and inconsistent quota dumps, including adjacent int64s."""
from pathlib import Path
import subprocess

script = Path(__file__).with_name('assert-interface-quota.awk')
def line(active='yes',generation='1',limit='9223372036854775807',remaining='9223372036854775806',error='0',invalid='0',contention='0'):
    return f'royd interface quota: error={error} active={active} generation={generation} limit={limit} remaining={remaining} invalid_drops={invalid} contention_drops={contention}\n'
good = [line(),line(remaining='0'),line(active='no',generation='0',limit='0',remaining='0'),line(generation='18446744073709551615')]
bad = [line(error='-5'),line(invalid='1'),line(contention='1'),line(generation='0'),line(limit='0'),
       line(limit='9223372036854775806',remaining='9223372036854775807'),line(limit='9223372036854775808'),
       line(remaining='9223372036854775808'),line(generation='18446744073709551616'),line(generation='01'),
       line(active='maybe'),line(active='no'),line(remaining='-1'),line().replace(' limit=',' other='),
       line()+line(),'missing\n',line().replace(' remaining=9223372036854775806',''),line().rstrip()+' extra\n']
for expected, cases in [(0,good),(1,bad)]:
    for witness in cases:
        result = subprocess.run(['awk','-f',str(script)],input=witness,text=True)
        assert (result.returncode == 0) == (expected == 0), witness
print('Quota dump unavailable/duplicate/metadata and exact int64 boundary contracts passed')
