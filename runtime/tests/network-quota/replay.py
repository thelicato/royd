"""Read-only replay of the complete scoped quota packet matrix."""
import json
from pathlib import Path
import re
import sys
from assess import assess_flow, need
from fixture import IP_BYTES


def matrix():
    rows = []
    for role in ('a', 'b', 'system'):
        for op in ('send', 'receive'):
            rows.append(('baseline-'+role+'-'+op, role, op, 1, 1, None, None))
    rows += [
        ('shared-a-egress', 'a', 'send', 1, 1, IP_BYTES+100, ('shared-budget-after', 2*IP_BYTES+100)),
        ('shared-system-ingress', 'system', 'receive', 1, 1, 100, None),
        ('crossing-b-egress', 'b', 'send', 1, 0, 0, None),
    ]
    for role, op in [('a', 'receive'), ('b', 'receive'), ('system', 'send')]:
        rows.append(('exhausted-'+role+'-'+op, role, op, 2, 0, 0, None))
    rows += [
        ('exact-b-ingress', 'b', 'receive', 1, 1, 0, ('exact-budget-after', IP_BYTES)),
        ('after-exact-a-egress', 'a', 'send', 1, 0, 0, None),
        ('before-update-a-egress', 'a', 'send', 1, 1, 2*IP_BYTES, ('old-budget-after', 3*IP_BYTES)),
        ('replacement-system-egress', 'system', 'send', 1, 1, 0, ('replacement-budget-after', IP_BYTES)),
    ]
    for role in ('a', 'b', 'system'):
        for op in ('send', 'receive'):
            transition = ('removed', 0) if role == 'a' and op == 'send' else None
            rows.append(('removed-'+role+'-'+op, role, op, 1, 1, 0, transition))
    rows += [
        ('sentinel-a-egress', 'a', 'send', 1, 1, 0, ('sentinel-removed', 0)),
        ('sentinel-system-ingress', 'system', 'receive', 1, 1, 0, None),
    ]
    return rows


def replay(directory):
    directory = Path(directory)
    load = lambda name: json.loads((directory/name).read_text())
    scope = load('scope.json')
    original = scope['original']
    workers = scope['workers']
    need(len({workers[r]['ready']['uid'] for r in ('a', 'b', 'system')}) == 3, 'distinct workers required')
    for role in ('a', 'b', 'system'):
        ready = workers[role]['ready']
        need(ready['gid'] == ready['uid'] and int(ready['cap_eff'], 16) == 0, 'worker privilege')
        need((ready['uid'] == 1000 and ready['importance'] == -1 and ready['cgroup'].strip() == '0::/royd/init')
             if role == 'system' else (10000 <= ready['uid'] < 20000 and ready['importance'] == 300
                                      and '/uid_'+str(ready['uid'])+'/' in ready['cgroup']), 'worker scope')
    plan = load('plan.json')
    need([p['label'] for p in plan] == [row[0] for row in matrix()], 'incomplete or reordered matrix')
    receipts = [json.loads(line) for line in (directory/'fixture.jsonl').read_text().splitlines()]
    identities = {(p['uid'], p['step']) for p in plan}
    need(all((r['uid'], r['step']) in identities for r in receipts), 'unplanned fixture receipt')
    expected = None
    generation = original['generation']
    output = []
    for planned, (label, role, op, count, passed, remaining, transition) in zip(plan, matrix()):
        if transition:
            name, limit = transition
            paths = [p for p in (directory/'observer-post').iterdir()
                     if re.fullmatch(r's[0-9]+-'+re.escape(name)+r'\.json', p.name)]
            need(len(paths) == 1, 'missing or duplicate control snapshot')
            expected = json.loads(paths[0].read_text())['quota']
            need(expected['present'] == (limit > 0) and expected['limit'] == expected['remaining'] == limit,
                 'control snapshot limit')
            if limit:
                need(expected['generation'] > generation, 'replacement generation did not advance')
                generation = expected['generation']
        item = load(label+'.json')
        # Recheck the final complete ledger, including packets arriving after a phase.
        item['fixture'] = receipts
        need(item['label'] == label and item['op'] == op and item['count'] == count and item['passed'] == passed,
             'packet matrix identity')
        need(item['ready'] == workers[role]['ready'], 'worker differs from frozen scope')
        for snapshots in (item['before'], item['after']):
            for side in ('pre', 'post'):
                need(snapshots[side]['query'] == scope['chains'], 'chain differs from frozen scope')
            for key in ('map_id', 'drops_map_id'):
                need(snapshots['post']['quota'][key] == original[key], 'quota map differs from frozen scope')
        if expected is not None:
            need(item['before']['post']['quota'] == expected, 'quota changed between packet windows')
            need(item['remaining'] == remaining, 'planned remainder differs from matrix')
        else:
            need(item['before']['post']['quota']['limit'] == (1 << 63)-1, 'baseline must be unlimited')
        result = assess_flow(item)
        generation = max(generation, item['after']['post']['quota']['generation'])
        need(planned == dict(label=label, role=role, **result), 'saved assessment differs from replay')
        if expected is not None: expected = item['after']['post']['quota']
        output.append(dict(label=label, **result))
    return dict(status='pass', scope='sequential-unsegmented-ipv4-udp', phases=output,
                attempted=sum(p['attempted'] for p in output), admitted=sum(p['admitted'] for p in output),
                denied=sum(p['denied'] for p in output))


if __name__ == '__main__':
    need(len(sys.argv) == 2, 'usage: replay.py EVIDENCE_DIRECTORY')
    print(json.dumps(replay(sys.argv[1]), indent=2))
