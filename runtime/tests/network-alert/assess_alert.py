"""Replay real Binder receipts against independent private IP-counter windows."""
import json
from pathlib import Path
import re
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'network-accounting'))
from assess import snapshots, assess as assess_udp


def load(root, name):
    return json.loads((root/name).read_text())


def lines(root, name):
    text = (root/name).read_text()
    assert text.endswith('\n'), 'incomplete receipt file'
    return [json.loads(line) for line in text.splitlines()]


def counters_equal(a, b):
    snapshots(a, b)
    assert a['counters'] == b['counters'], 'uncontrolled IP usage between measurement windows'


def used(start, end):
    snapshots(start, end)
    delta = [b-a for a, b in zip(start['counters'], end['counters'])]
    assert min(delta) >= 0
    return delta[1]+delta[3]


def assess(root):
    root = Path(root)
    scope = load(root, 'scope.json')
    windows = load(root, 'windows.json')
    assert [w['label'] for w in windows] == ['first', 'old', 'replacement', 'second']
    assert [w['bytes'] for w in windows] == [628737, 628737, 1257472, 628737]
    original = scope['original']
    assert original['bytes'] > 628737 and original['armed'] and original['error'] == 0
    probe = lines(root, 'probe.jsonl')
    assert all(r['nonce'] == scope['nonce'] and r['uid'] == 0 for r in probe)
    assert len({r['pid'] for r in probe}) == 1 and probe[0]['pid'] > 1
    assert [r['time_ns'] for r in probe] == sorted(r['time_ns'] for r in probe)
    ready = [r for r in probe if r['event'] == 'ready']
    assert len(ready) == 1 and ready[0]['aidl_version'] == 15 and ready[0]['netd_pid'] == scope['netd_pid'] > 1
    callbacks = [r for r in probe if r['event'] == 'callback']
    assert len(callbacks) == 2
    for index, receipt in enumerate(callbacks, 1):
        assert receipt['name'] == 'globalAlert' and receipt['interface'] == 'eth0'
        assert receipt['caller_uid'] == 0 and receipt['caller_pid'] == 0
        assert receipt['callbacks'] == index
    commands = [r for r in probe if r['event'] == 'command']
    assert [r['sequence'] for r in commands] == list(range(1, len(commands)+1))
    invalid = [r for r in commands if r['operation'] == 'invalid']
    assert [r['bytes'] for r in invalid] == [0, -1]
    assert all(r['error_code'] == 34 and r['callbacks'] == 0 for r in invalid)
    for w in windows:
        assert w['command'] in commands and w['command']['operation'] == 'arm'
        assert w['command']['bytes'] == w['bytes'] and w['command']['error_code'] == 0
        a, b = w['state_before'], w['state_after']
        assert b['generation'] == a['generation']+1 and b['committed'] == a['committed']
        assert b['bytes'] == w['bytes'] and b['armed'] and b['error'] == 0 and b['sample_ms'] == 250
        counters_equal(w['baseline_before'], w['baseline_after'])
    denied = lines(root, 'denied.jsonl')
    assert [r['event'] for r in denied] == ['identity', 'denied-arm', 'denied-listener']
    assert all(r['uid'] == scope['uid'] and r['nonce'] == scope['nonce'] for r in denied)
    assert len({r['pid'] for r in denied}) == 1 and 10000 <= scope['uid'] < 20000
    status = denied[0]['status']
    for key in ['Uid', 'Gid']:
        assert re.findall('^'+key+r':\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s*$', status, re.M) == [(str(scope['uid']),)*4]
    cap = re.findall(r'^CapEff:\s*([0-9a-f]+)\s*$', status, re.M)
    assert len(cap) == 1 and int(cap[0], 16) == 0
    assert all(r['exception'] == 'java.lang.SecurityException' for r in denied[1:])
    receipts = lines(root, 'fixture.log')
    assert receipts[0]['nonce'] == scope['nonce'] and receipts[0]['event'] == 'ready'
    phases = {}
    for phase in range(1, 7):
        before, after = [load(root, f'observer/p{phase}-{tag}.json') for tag in ('before', 'after')]
        workers = lines(root, f'worker-{phase}.log')
        assert workers[1]['packets'] == (1 if phase in (2, 6) else 256)
        assess_udp(before, after, [workers], receipts, phase, 'normal')
        phases[phase] = (before, after)
    quiets = {name: load(root, name+'-quiet.json') for name in
              ['first-below','first-crossed','old-below','replacement-below','second-below','second-crossed']}
    for name, quiet in quiets.items():
        assert quiet['end_ns']-quiet['start_ns'] >= 1_500_000_000 and quiet['seconds'] >= 1.5
        assert quiet['reply'] in commands and quiet['reply']['operation'] == 'status'
        assert quiet['reply']['callbacks'] == quiet['callbacks']
    for w, phase, name, expected in zip(windows, [1,3,4,5], ['first-below','old-below','replacement-below','second-below'], [0,1,1,1]):
        quiet = quiets[name]
        counters_equal(w['baseline_after'], phases[phase][0])
        counters_equal(phases[phase][1], quiet['counters'])
        assert used(w['baseline_before'], quiet['counters']) == 628736 < w['bytes']
        assert quiet['callbacks'] == expected
    # Both first/second below controls stop exactly one IP byte short of the threshold.
    for w, phase, name, index in [(windows[0],2,'first-crossed',1),(windows[3],6,'second-crossed',2)]:
        below = quiets['first-below' if index == 1 else 'second-below']
        counters_equal(below['counters'], phases[phase][0])
        counters_equal(phases[phase][1], quiets[name]['counters'])
        assert used(w['baseline_after'], quiets[name]['counters']) == 631192 > w['bytes']
        assert quiets[name]['callbacks'] == index
        assert below['reply']['time_ns'] < callbacks[index-1]['time_ns'] < quiets[name]['reply']['time_ns']
        framework = load(root, name+'-framework.json')
        assert framework['generation'] == w['state_after']['generation']+1
        assert framework['bytes'] == original['bytes'] and framework['armed'] and framework['error'] == 0
        assert framework['committed'] == w['state_after']['committed']+1
    # Old accumulated traffic would cross the replaced threshold; new baseline does not.
    counters_equal(quiets['old-below']['counters'], windows[2]['baseline_before'])
    assert used(windows[1]['baseline_before'], quiets['replacement-below']['counters']) > windows[1]['bytes']
    assert used(windows[2]['baseline_after'], quiets['replacement-below']['counters']) < windows[2]['bytes']
    return dict(status='pass', callbacks=2, threshold=628737, below_ip_bytes=628736,
                crossed_ip_bytes=631192, restored_framework_bytes=original['bytes'],
                replaced_window_status='pass', invalid_and_denied_status='pass', native_udp_phases=6)


if __name__ == '__main__':
    print(json.dumps(assess(Path(sys.argv[1]))))
