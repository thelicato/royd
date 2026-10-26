#!/usr/bin/env python3
"""Controlled ordinary-UID denial at the two interface-accounting boundaries."""
import json
import re
from pathlib import Path
from assess import snapshots

PACKETS = 64
PAYLOAD = 1200
OEM_DENY = 2048
PACKAGES = ['org.royd.networkprobe', 'org.royd.networkcontrol']


def policy_map(text, uids):
    assert 'Failed to' not in text
    configuration = re.findall(r'^\s*current ownerMatch configuration: ([0-9]+)([^\n]*)$', text, re.M)
    assert len(configuration) == 1 and text.count('sUidOwnerMap:') == text.count('sUidPermissionMap:') == 1
    value, tags = configuration[0]
    value = int(value)
    assert bool(value & OEM_DENY) == ('OEM_DENY_3_MATCH' in tags.split())
    owners = text.split('sUidOwnerMap:', 1)[1].split('sUidPermissionMap:', 1)[0]
    rules = []
    for uid in uids:
        rows = re.findall(r'^\s*' + str(uid) + r'\s+([^\n]+)$', owners, re.M)
        assert len(rows) <= 1
        rules.append(set(rows[0].split()) if rows else set())
    return value, rules


def assess(before, after, ready, application, receipts, phase, fixture, identity, cgroup,
           process_status, uid_states, chain, rules, current_map, baseline_map):
    snapshots(before, after)
    assert phase in range(8, 14) and len(ready) == 2
    role = (phase - 8) % 2
    blocked = phase == 10
    enabled = phase in (10, 11)
    uids = [r['uid'] for r in ready]
    assert len(set(uids)) == 2 and all(type(uid) is int and 10000 <= uid < 20000 for uid in uids)
    for index, r in enumerate(ready):
        assert r['event'] == 'ready' and r['role'] == ('target' if index == 0 else 'control')
        assert r['gid'] == r['uid'] and r['pid'] > 1 and int(r['cap_eff'], 16) == 0
        assert r['importance'] == 300 and r['nonce'] == fixture['nonce'] and r['remote'] == fixture['address']
        assert r['cgroup'] == f"0::/royd/uid_{r['uid']}/pid_{r['pid']}\n"
    assert application['event'] == 'policy-complete' and application['phase'] == phase
    for key in ('uid', 'pid', 'role', 'nonce', 'local', 'remote'):
        assert application[key] == ready[role][key], key
    assert identity == f"{ready[role]['pid']} {uids[role]}\n"
    assert cgroup == ready[role]['cgroup'] and uid_states == ['10 (SERVICE)', '10 (SERVICE)']
    for key in ('Uid', 'Gid'):
        matches = re.findall(r'^' + key + r':\s+([0-9]+)\s+([0-9]+)\s+([0-9]+)\s+([0-9]+)\s*$', process_status, re.M)
        assert matches == [(str(uids[role]),)*4], key
    caps = re.findall(r'^CapEff:\s*([0-9a-f]+)\s*$', process_status, re.M)
    assert len(caps) == 1 and int(caps[0], 16) == 0
    assert application['importance'] == 300 and 0 < application['start_ns'] < application['end_ns']
    assert application['send_attempts'] == PACKETS
    assert application['send_successes'] == (0 if blocked else PACKETS)
    assert application['send_eperm'] == (PACKETS if blocked else 0)
    assert application['receive_packets'] == (0 if blocked else PACKETS)
    assert application['receive_timeout'] == blocked
    assert bool(application['denial']) == blocked
    if blocked:
        assert application['end_ns'] - application['start_ns'] >= 1_000_000_000
    assert chain == ('chain:enabled' if enabled else 'chain:disabled')
    for index, package in enumerate(PACKAGES):
        expected = 'deny' if enabled and index == 0 else 'allow'
        assert rules[index] == package + ':' + expected
    base_config, base_owners = policy_map(baseline_map, uids)
    config, owners = policy_map(current_map, uids)
    assert not base_config & OEM_DENY and all('OEM_DENY_3_MATCH' not in owner for owner in base_owners)
    assert config == base_config | (OEM_DENY if enabled else 0)
    for index in range(2):
        assert ('OEM_DENY_3_MATCH' in owners[index]) == (enabled and index == 0)
        assert owners[index] - {'OEM_DENY_3_MATCH'} == base_owners[index], 'unrelated UID rules changed'
    rows = [r for r in receipts if r.get('event') == 'policy-receive' and r['phase'] == phase]
    completions = [r for r in receipts if r.get('event') == 'policy-complete' and r['phase'] == phase]
    if blocked:
        assert rows == completions == [], 'denied target reached the fixture'
        pushes = [r for r in receipts if r.get('event') == 'policy-push']
        assert len(pushes) == 1
        row = pushes[0]
        assert row['phase'] == phase and row['uid'] == uids[role] and row['peer'] == ready[role]['local']
        assert row['packets'] == PACKETS and row['payload_bytes'] == PACKETS * PAYLOAD
    else:
        assert len(rows) == PACKETS and sorted(r['sequence'] for r in rows) == list(range(PACKETS))
        assert all(r['uid'] == uids[role] and r['peer'] == ready[role]['local'] and r['payload_bytes'] == PAYLOAD for r in rows)
        assert len(completions) == 1
        row = completions[0]
        assert row['uid'] == uids[role] and row['peer'] == ready[role]['local']
        assert row['packets'] == PACKETS and row['payload_bytes'] == PACKETS * PAYLOAD
    expected = [PACKETS, PACKETS * (PAYLOAD + 28), 0 if blocked else PACKETS, 0 if blocked else PACKETS * (PAYLOAD + 28)]
    delta = [b-a for a, b in zip(before['counters'], after['counters'])]
    assert delta == expected, f'policy IP counters: got {delta}, expected {expected}'
    assert before['tcp'] == after['tcp'], 'TCP traffic in the policy measurement window'
    for index in range(2):
        change = {k: after['observed'][index][k] - before['observed'][index][k] for k in before['observed'][index]}
        n = 0 if blocked and index == 1 else PACKETS
        assert change == dict(skbs=n, segments=n, gso_skbs=0, raw_bytes=n * (PAYLOAD + 28 + 14), other_ip_skbs=0, errors=0)
    return dict(phase=phase, role=application['role'], state='blocked' if enabled else 'baseline' if phase < 10 else 'restored',
                rx_packets=expected[0], rx_ip_bytes=expected[1], tx_packets=expected[2], tx_ip_bytes=expected[3], status='pass')


def main():
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument('directory', type=Path)
    root = parser.parse_args().directory
    receipts = [json.loads(line) for line in (root/'fixture.log').read_text().splitlines()]
    fixture = receipts[0]
    assert fixture['event'] == 'ready'
    ready = [json.loads((root/f'policy-ready-{role}.json').read_text()) for role in range(2)]
    baseline = (root/'phase-8/bpf.log').read_text()
    for phase in range(8, 14):
        role = (phase-8) % 2
        d = root/f'phase-{phase}'
        before, after = [json.loads((root/f'observer/p{phase}-{tag}.json').read_text()) for tag in ('before', 'after')]
        result = assess(before, after, ready, json.loads((d/'app.json').read_text()), receipts, phase, fixture,
                        (root/f'policy-identity-{role}.txt').read_text(), (d/'cgroup.log').read_text(), (d/'proc-status.log').read_text(),
                        [(d/f'uid-state-{tag}.log').read_text().strip() for tag in ('before', 'after')], (d/'chain.log').read_text().strip(),
                        [(d/f'rule-{package}.log').read_text().strip() for package in PACKAGES], (d/'bpf.log').read_text(), baseline)
        print(json.dumps(result), flush=True)


if __name__ == '__main__':
    main()
