"""Independent packet, receipt, identity and byte-budget acceptance oracles."""
import hashlib
from fixture import IP_BYTES, SIZE, packet


def need(value, reason):
    if not value:
        raise ValueError(reason)


def assess_flow(item):
    before, after = item['before'], item['after']
    uid, step, op, count, passed = [item[k] for k in ('uid', 'step', 'op', 'count', 'passed')]
    need(op in ('send', 'receive') and 0 <= passed <= count <= 64 and count > 0, 'flow plan')
    for snapshots in (before, after):
        pre, post = snapshots['pre'], snapshots['post']
        need(pre['ifindex'] == post['ifindex'] and pre['map_id'] == post['map_id'], 'different accounting sources')
        for d in (0, 1):
            chain = pre['query'][d]
            need(chain == post['query'][d] and len(chain) == len(set(chain)) == 4
                 and chain[0] == pre['production_links'][d] and chain[2] == post['production_links'][d],
                 'quota is not between the two observers')
    direction = 1 if op == 'send' else 0
    for side in ('pre', 'post'):
        a, b = before[side], after[side]
        for key in ('ifindex', 'map_id', 'production_links', 'query'):
            need(a[key] == b[key], 'changed ' + side + ' ' + key)
        for d in (0, 1):
            expected = (count if side == 'pre' else passed) if d == direction else 0
            for key in ('skbs', 'segments'):
                need(b['observed'][d][key] - a['observed'][d][key] == expected, side + ' ' + key)
            need(b['observed'][d]['raw_bytes'] - a['observed'][d]['raw_bytes'] == expected * (IP_BYTES + 14),
                 side + ' Ethernet skb size')
            for key in ('other_ip_skbs', 'errors', 'gso_skbs'):
                need(b['observed'][d][key] == a['observed'][d][key], side + ' noise/error/aggregation')
        expected = [0, 0, 0, 0]
        expected[2 * direction], expected[2 * direction + 1] = count, count * IP_BYTES
        need([y - x for x, y in zip(a['counters'], b['counters'])] == expected,
             'accounting must include quota attempts')
    need(before['pre']['counters'] == before['post']['counters']
         and after['pre']['counters'] == after['post']['counters'], 'non-quiescent source snapshots')
    a, b = before['post']['quota'], after['post']['quota']
    for key in ('present', 'map_id', 'drops_map_id', 'generation', 'limit', 'invalid', 'contention'):
        need(a[key] == b[key], 'changed quota ' + key)
    need(a['invalid'] == a['contention'] == 0, 'quota backend fault')
    need(a['map_id'] > 0 and a['drops_map_id'] > 0, 'unavailable quota maps')
    need(a['generation'] > 0 and 0 <= a['remaining'] <= a['limit'] < (1 << 63)
         if a['present'] else a['generation'] == a['limit'] == a['remaining'] == 0,
         'invalid quota metadata')
    need(b['remaining'] == item['remaining'], 'wrong remaining budget')
    admitted = min(count, a['remaining'] // IP_BYTES) if a['present'] else count
    remainder = a['remaining'] - count * IP_BYTES if a['present'] and admitted == count else 0
    need(passed == admitted and b['remaining'] == remainder, 'packet admission differs from starting budget')
    app, ready = item['app'], item['ready']
    need(0 < app['ready_ns'] <= app['released_ns'] <= app['finished_ns'], 'worker timing order')
    for key in ('uid', 'pid', 'nonce', 'local', 'remote', 'importance'):
        need(app[key] == ready[key], 'changed worker ' + key)
    need(app['uid'] == uid and app['step'] == step and app['op'] == op and app['count'] == count,
         'application result identity')
    if op == 'send':
        need(app['send_successes'] + app['send_enobufs'] == count and app['received'] == 0,
             'send observation')
        if passed:
            need(app['send_enobufs'] == 0, 'allowed send failed')
    else:
        need(app['received'] == passed and app['receive_timeout'] is True
             and app['send_successes'] == app['send_enobufs'] == 0, 'receive observation')
    receipts = [r for r in item['fixture'] if r['uid'] == uid and r['step'] == step]
    expected = passed if op == 'send' else count
    need(len(receipts) == expected, 'fixture receipt count')
    need({r['sequence'] for r in receipts} == set(range(expected)), 'fixture sequence')
    need(all(r['count'] == count and r['event'] == ('receive' if op == 'send' else 'push')
             and r['kind'] == (1 if op == 'send' else 2) for r in receipts), 'fixture identity')
    need(all(r['peer'] == ready['local'] and r['sha256'] == hashlib.sha256(packet(
        bytes.fromhex(ready['nonce']), step, uid, r['sequence'], count, r['kind'])).hexdigest()
        for r in receipts), 'fixture endpoint or payload digest')
    return dict(uid=uid, step=step, operation=op, attempted=count, admitted=passed,
                denied=count-passed, remaining=b['remaining'], ip_bytes=IP_BYTES,
                payload_bytes=SIZE, generation=b['generation'])
