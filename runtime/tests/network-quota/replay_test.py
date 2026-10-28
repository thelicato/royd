import json
import copy
import hashlib
from pathlib import Path
import tempfile
import unittest
from replay import matrix, replay
from assess import assess_flow
from assess_test import example
from fixture import IP_BYTES, packet


def complete_fixture(directory):
    """Synthetic packet vectors, not Android runtime evidence."""
    original = dict(example()['before']['post']['quota'], remaining=(1 << 63)-1, limit=(1 << 63)-1)
    workers = {}
    for i, (role, uid) in enumerate([('a', 10096), ('b', 10097), ('system', 1000)]):
        workers[role] = dict(ready=dict(example()['ready'], uid=uid, gid=uid, pid=500+i,
            cap_eff='0', local='172.17.0.2:'+str(40000+i), importance=-1 if role == 'system' else 300,
            cgroup='0::/royd/init' if role == 'system' else '0::/royd/uid_'+str(uid)+'/pid_'+str(500+i)))
    scope = dict(original=original, workers=workers, chains=example()['before']['pre']['query'])
    (directory/'scope.json').write_text(json.dumps(scope))
    (directory/'observer-post').mkdir()
    state, generation, steps, plan, ledger = copy.deepcopy(original), original['generation'], {}, [], []
    for n, (label, role, op, count, passed, _, transition) in enumerate(matrix()):
        if transition:
            name, limit = transition
            if limit: generation += 1
            state = dict(original, present=bool(limit), limit=limit, remaining=limit,
                         generation=generation if limit else 0)
            (directory/'observer-post'/('s'+str(n)+'-'+name+'.json')).write_text(json.dumps(dict(quota=state)))
        value = example(op, passed, count)
        steps[role] = steps.get(role, 0)+1
        ready, step = workers[role]['ready'], steps[role]
        value.update(label=label, uid=ready['uid'], ready=ready, step=step)
        value['app'].update(ready, step=step)
        value['before']['post']['quota'] = copy.deepcopy(state)
        if state['present']:
            state = dict(state, remaining=max(0, state['remaining']-count*IP_BYTES))
        value['after']['post']['quota'] = copy.deepcopy(state)
        value['remaining'] = state['remaining']
        for receipt in value['fixture']:
            receipt.update(uid=ready['uid'], step=step, peer=ready['local'])
            receipt['sha256'] = hashlib.sha256(packet(bytes.fromhex(ready['nonce']), step, ready['uid'],
                receipt['sequence'], count, receipt['kind'])).hexdigest()
        ledger.extend(value['fixture'])
        plan.append(dict(label=label, role=role, **assess_flow(value)))
        (directory/(label+'.json')).write_text(json.dumps(value))
    (directory/'plan.json').write_text(json.dumps(plan))
    (directory/'fixture.jsonl').write_text(''.join(json.dumps(r)+'\n' for r in ledger))


class Replay(unittest.TestCase):
    def test_complete_matrix_and_late_unplanned_receipt(self):
        with tempfile.TemporaryDirectory() as name:
            directory = Path(name)
            complete_fixture(directory)
            result = replay(directory)
            self.assertEqual((len(result['phases']), result['attempted'], result['admitted'], result['denied']),
                             (24, 27, 19, 8))
            with (directory/'fixture.jsonl').open('a') as output:
                output.write(json.dumps(dict(uid=10096, step=128))+'\n')
            with self.assertRaisesRegex(ValueError, 'unplanned'):
                replay(directory)

    def test_forged_between_phase_exhaustion_is_rejected(self):
        with tempfile.TemporaryDirectory() as name:
            directory = Path(name)
            complete_fixture(directory)
            path = directory/'crossing-b-egress.json'
            value = json.loads(path.read_text())
            value['before']['post']['quota']['remaining'] = 0
            # This would still pass the individual packet oracle: an already empty
            # budget drops the packet too. It cannot prove exhaustion by crossing.
            assess_flow(value)
            path.write_text(json.dumps(value))
            with self.assertRaisesRegex(ValueError, 'between packet windows'):
                replay(directory)

    def test_missing_duplicate_or_reordered_phases_are_rejected(self):
        workers = {}
        for role, uid in [('a', 10096), ('b', 10097), ('system', 1000)]:
            workers[role] = dict(ready=dict(uid=uid, gid=uid, cap_eff='0',
                importance=-1 if role == 'system' else 300,
                cgroup='0::/royd/init' if role == 'system' else '0::/royd/uid_'+str(uid)+'/pid_50'))
        with tempfile.TemporaryDirectory() as name:
            directory = Path(name)
            (directory/'scope.json').write_text(json.dumps(dict(original=dict(generation=1), workers=workers)))
            plan = [dict(label=row[0]) for row in matrix()]
            alternatives = [plan[:-1], plan+[plan[-1]], plan[1:]+plan[:1]]
            for value in alternatives:
                (directory/'plan.json').write_text(json.dumps(value))
                with self.subTest(plan=value), self.assertRaisesRegex(ValueError, 'matrix'):
                    replay(directory)


if __name__ == '__main__': unittest.main()
