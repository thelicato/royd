#!/usr/bin/env python3
"""Exact controlled IPv4 UDP accounting, independent of the production parser."""
import json
from pathlib import Path

PAYLOAD = 1200

def snapshots(before, after):
    for snapshot in (before, after):
        assert len(snapshot['counters']) == 4 and len(snapshot['observed']) == 2
        assert len(snapshot['production_links']) == len(snapshot['query']) == 2
        assert all(type(v) is int and v >= 0 for v in snapshot['counters'])
        for observation in snapshot['observed']:
            assert set(observation) == {'skbs', 'segments', 'gso_skbs', 'raw_bytes', 'other_ip_skbs', 'errors'}
            assert all(type(v) is int and v >= 0 for v in observation.values())
    assert before['ifindex'] == after['ifindex'] > 1
    assert before['map_id'] == after['map_id'] > 0
    assert before['production_links'] == after['production_links']
    assert before['query'] == after['query']

def assess(before, after, workers, receipts, phase, kind):
    assert kind in ('raw', 'normal', 'segmented', 'concurrent', 'loopback')
    snapshots(before, after)
    loopback = kind == 'loopback'
    segmented = kind in ('segmented', 'concurrent')
    expected_uids = [0, 1000] if kind == 'concurrent' else [0] if kind == 'raw' else [1000]
    assert len(workers) == len(expected_uids)
    completed = []
    for logs, uid in zip(workers, expected_uids):
        assert len(logs) == 2
        ready, done = logs
        assert ready['event'] == 'ready' and done['event'] == 'complete'
        assert ready['uid'] == ready['gid'] == done['uid'] == uid
        assert ready['pid'] > 1 and ready['cap_eff'] and ready['cgroup']
        if uid == 1000:
            assert int(ready['cap_eff'], 16) == 0, 'system-UID worker has effective capabilities'
        assert done['phase'] == phase and done['packets'] > 0
        assert done['payload_bytes'] == done['packets'] * PAYLOAD
        assert done['segmented'] == segmented and done['loopback'] == loopback
        assert done['raw'] == (kind == 'raw') and 0 < done['start_ns'] < done['end_ns']
        if not loopback:
            rows = [r for r in receipts if r.get('event') == 'complete' and r['phase'] == phase and r['uid'] == uid]
            assert len(rows) == 1
            row = rows[0]
            assert row['packets'] == done['packets'] and row['payload_bytes'] == done['payload_bytes']
            assert row['segmented'] == segmented and row['peer'] == done['local']
        else:
            assert done['local'].startswith('127.0.0.1:') and done['remote'].startswith('127.0.0.1:')
        completed.append(done)
    if kind == 'concurrent':
        assert max(r['start_ns'] for r in completed) < min(r['end_ns'] for r in completed), 'send/receive intervals did not overlap'
    packets = 0 if loopback else sum(r['packets'] for r in completed)
    expected = [packets, packets * (PAYLOAD + 20 + 8)] * 2
    delta = [b - a for a, b in zip(before['counters'], after['counters'])]
    assert len(delta) == 4 and delta == expected, f'IP counters: got {delta}, expected {expected}'
    for start, end in zip(before['observed'], after['observed']):
        change = {k: end[k] - start[k] for k in start}
        assert all(v >= 0 for v in change.values())
        assert change['errors'] == change['other_ip_skbs'] == 0, 'unrelated traffic or observer read failure in measurement window'
        assert change['segments'] == packets
        if loopback:
            assert change['skbs'] == change['gso_skbs'] == change['raw_bytes'] == 0
        elif segmented:
            assert 0 < change['gso_skbs'] <= change['skbs'] < packets, 'segmentation not observed at this TCX hook'
            assert change['raw_bytes'] < packets * (PAYLOAD + 28 + 14)
        else:
            assert change['gso_skbs'] == 0 and change['skbs'] == packets
            assert change['raw_bytes'] == packets * (PAYLOAD + 28 + 14)
    return {'phase': phase, 'kind': kind, 'packets_per_direction': packets, 'ip_bytes_per_direction': expected[1], 'status': 'pass'}

def fixture_socket(receipts):
    rows = [r for r in receipts if r.get('event') == 'udp-fixture-stop']
    assert len(rows) == 1, 'missing or duplicated owned fixture socket evidence'
    state = rows[0]['socket']
    assert 'error' not in state, 'owned fixture socket diagnostics unavailable'
    assert state['local'] == receipts[0]['address']
    assert type(state['receive_buffer_bytes']) is int and state['receive_buffer_bytes'] > 0
    assert state['socket_drops'] == 0, 'owned fixture UDP receive queue dropped packets'
    assert state['queue_bytes_hex'] == '00000000:00000000', 'owned fixture queue was not drained'
    return dict(status='pass', receive_buffer_bytes=state['receive_buffer_bytes'], socket_drops=0)

def main():
    import argparse
    p = argparse.ArgumentParser()
    p.add_argument('directory', type=Path)
    p.add_argument('--fixture-socket', action='store_true')
    a = p.parse_args()
    root = a.directory
    receipts = [json.loads(x) for x in (root/'fixture.log').read_text().splitlines()]
    if a.fixture_socket:
        print(json.dumps(fixture_socket(receipts)), flush=True)
        return
    for phase, kind in enumerate(('raw', 'normal', 'segmented', 'concurrent', 'loopback'), 1):
        d = root/f'phase-{phase}'
        uids = [0, 1000] if kind == 'concurrent' else [0] if kind == 'raw' else [1000]
        workers = [[json.loads(x) for x in (d/f'worker-{uid}.log').read_text().splitlines()] for uid in uids]
        print(json.dumps(assess(json.loads((root/f'observer/p{phase}-before.json').read_text()), json.loads((root/f'observer/p{phase}-after.json').read_text()), workers, receipts, phase, kind)), flush=True)

if __name__ == '__main__':
    main()
