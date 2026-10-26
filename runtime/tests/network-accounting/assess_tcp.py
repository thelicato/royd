#!/usr/bin/env python3
"""TCP stream conservation and MSS-derived wire totals, not the product parser."""
import hashlib
import ipaddress
import json
import struct
from pathlib import Path
from assess import snapshots

STREAM_BYTES = 1 << 20
RECORD_FIELDS = {'skb_len', 'ip_len', 'ip_total', 'tcp_len', 'sequence', 'gso_size',
                 'gso_segs', 'flags', 'source', 'destination', 'source_port', 'destination_port'}


def payload_hash(nonce, phase, uid, reply):
    header = bytes.fromhex(nonce) + struct.pack('!III', phase, uid, STREAM_BYTES) + bytes([reply, 0, 0, 0])
    data = header + bytes((i ^ phase ^ uid ^ reply) & 255 for i in range(32, STREAM_BYTES))
    return hashlib.sha256(data).hexdigest()


def endpoint(value):
    host, port = value.rsplit(':', 1)
    address = ipaddress.IPv4Address(host)
    assert address.is_private and 0 < int(port) <= 65535
    return int(address), int(port)


def direction(records):
    """Require one lossless byte stream and independently derive segment totals."""
    assert records
    syn = [r for r in records if r['flags'] & 2]
    fin = [r for r in records if r['flags'] & 1]
    assert len(syn) == len(fin) == 1, 'incomplete/retransmitted handshake or teardown'
    base = (syn[0]['sequence'] + 1) % (1 << 32)
    intervals, packet_count, header_bytes, gso_skbs = [], 0, 0, 0
    widths = set()
    for r in records:
        assert set(r) == RECORD_FIELDS
        assert all(type(v) is int and 0 <= v < 1 << 32 for v in r.values())
        assert r['ip_len'] == 20 and 20 <= r['tcp_len'] <= 60 and r['tcp_len'] % 4 == 0
        assert not r['flags'] & 4, 'TCP reset'
        headers = r['ip_len'] + r['tcp_len']
        widths.add(r['tcp_len'])
        assert headers <= r['ip_total'] <= 65535 and r['skb_len'] >= headers + 14
        if r['gso_size']:
            payload = r['skb_len'] - 14 - headers
            segments = max(1, (payload + r['gso_size'] - 1) // r['gso_size'])
        else:
            assert r['ip_total'] <= r['skb_len'] - 14
            payload = r['ip_total'] - headers
            segments = 1
        if segments > 1:
            assert r['gso_segs'] == segments and r['gso_size'] > 0
            gso_skbs += 1
        else:
            assert r['gso_segs'] in (0, 1)
            assert payload == r['ip_total'] - headers
        if payload:
            assert not r['flags'] & 2
            offset = (r['sequence'] - base) % (1 << 32)
            intervals.append((offset, offset + payload))
        if r['flags'] & 1:
            assert ((r['sequence'] - base) % (1 << 32)) + payload == STREAM_BYTES
        packet_count += segments
        header_bytes += segments * headers
    assert gso_skbs > 0, 'no actual TCP segmentation at this hook/flow'
    assert any(width > 20 for width in widths), 'TCP options not exercised'
    offset = 0
    for start, end in sorted(intervals):
        assert start == offset and start < end <= STREAM_BYTES, 'missing, duplicated or retransmitted stream bytes'
        offset = end
    assert offset == STREAM_BYTES, 'stream bytes do not match the independently verified transfer'
    return packet_count, STREAM_BYTES + header_bytes, gso_skbs, sorted(widths)


def assess(before, after, workers, receipts, phase, fixture):
    snapshots(before, after)
    uids = [1000] if phase == 6 else [0, 1000]
    assert phase in (6, 7) and len(workers) == len(uids)
    server = endpoint(fixture['tcp_address'])
    flows = {}
    done_rows = []
    for logs, uid in zip(workers, uids):
        assert len(logs) == 2
        ready, done = logs
        assert ready['event'] == 'ready' and done['event'] == 'tcp-complete'
        assert ready['uid'] == ready['gid'] == done['uid'] == uid
        assert ready['pid'] > 1 and ready['cgroup'] and ready['cap_eff']
        if uid == 1000:
            assert int(ready['cap_eff'], 16) == 0
        assert done['phase'] == phase and done['payload_bytes'] == STREAM_BYTES
        assert 0 < done['start_ns'] < done['end_ns'] and endpoint(done['remote']) == server
        local = endpoint(done['local'])
        assert local not in flows
        flows[local] = [[], []]
        rows = [r for r in receipts if r.get('event') == 'tcp-complete' and r['phase'] == phase and r['uid'] == uid]
        assert len(rows) == 1 and rows[0]['peer'] == done['local']
        row = rows[0]
        assert row['payload_bytes'] == STREAM_BYTES
        for key, reply in (('upload_sha256', 0), ('download_sha256', 1)):
            assert done[key] == row[key] == payload_hash(fixture['nonce'], phase, uid, reply)
        done_rows.append(done)
    if phase == 7:
        assert max(r['start_ns'] for r in done_rows) < min(r['end_ns'] for r in done_rows), 'TCP workers did not overlap'
    assert len(before['tcp']) == len(after['tcp']) == 2
    for index, (start, end) in enumerate(zip(before['tcp'], after['tcp'])):
        assert end[:len(start)] == start, 'TCP header ledger changed or lost records'
        assert len(start) < len(end) <= 4096
        for event in end[len(start):]:
            src = event['source'], event['source_port']
            dst = event['destination'], event['destination_port']
            local = dst if index == 0 else src
            assert local in flows and (src if index == 0 else dst) == server, 'unexpected TCP peer'
            flows[local][index].append(event)
        assert before['observed'][index] == after['observed'][index], 'UDP, unrelated IP traffic or observer errors in TCP window'
    totals = [[0, 0], [0, 0]]
    gso = [0, 0]
    widths = set()
    for records in flows.values():
        for index in range(2):
            packets, byte_count, aggregates, options = direction(records[index])
            totals[index][0] += packets
            totals[index][1] += byte_count
            gso[index] += aggregates
            widths.update(options)
    expected = totals[0] + totals[1]
    delta = [b - a for a, b in zip(before['counters'], after['counters'])]
    assert delta == expected, f'TCP IP counters: got {delta}, expected {expected}'
    return dict(phase=phase, kind='tcp-single' if phase == 6 else 'tcp-concurrent',
                stream_bytes_per_flow_direction=STREAM_BYTES, flows=len(flows),
                rx_packets=totals[0][0], rx_ip_bytes=totals[0][1], tx_packets=totals[1][0], tx_ip_bytes=totals[1][1],
                gso_skbs_per_direction=gso, tcp_header_widths=sorted(widths), status='pass')


def main():
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument('directory', type=Path)
    root = parser.parse_args().directory
    receipts = [json.loads(line) for line in (root/'fixture.log').read_text().splitlines()]
    fixture = receipts[0]
    assert fixture['event'] == 'ready'
    for phase in (6, 7):
        uids = [1000] if phase == 6 else [0, 1000]
        workers = [[json.loads(line) for line in (root/f'phase-{phase}/worker-{uid}.log').read_text().splitlines()] for uid in uids]
        before, after = [json.loads((root/f'observer/p{phase}-{tag}.json').read_text()) for tag in ('before', 'after')]
        print(json.dumps(assess(before, after, workers, receipts, phase, fixture)), flush=True)


if __name__ == '__main__':
    main()
