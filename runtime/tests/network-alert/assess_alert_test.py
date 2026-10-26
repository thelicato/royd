import copy
import json
from pathlib import Path
import tempfile
import unittest
from assess_alert import assess


def write(root, name, value, jsonl=False):
    p = root/name
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text((''.join(json.dumps(v)+'\n' for v in value) if jsonl else json.dumps(value)+'\n'))


def case(root):
    nonce = '0'*32
    original = dict(generation=2, bytes=2097152, armed=True, committed=0, error=0, sample_ms=250)
    write(root, 'scope.json', dict(nonce=nonce, uid=10096, netd_pid=200, original=original))
    def event(kind, tick, **data):
        return dict(event=kind, time_ns=tick, nonce=nonce, pid=5000, uid=0, **data)
    probe = [event('ready', 10, aidl_version=15, netd_pid=200)]
    commands = {}
    for seq, tick, operation, amount, callbacks in [
        (1,21,'invalid',0,0),(2,22,'invalid',-1,0),(3,30,'arm',628737,0),
        (4,50,'status',0,0),(5,70,'status',0,1),(6,80,'arm',628737,1),
        (7,90,'status',0,1),(8,100,'arm',1257472,1),(9,110,'status',0,1),
        (10,120,'arm',628737,1),(11,150,'status',0,1),(12,170,'status',0,2)]:
        commands[seq] = event('command', tick, sequence=seq, operation=operation, bytes=amount,
                              callbacks=callbacks, error_code=34 if operation == 'invalid' else 0)
        probe.append(commands[seq])
    probe += [event('callback', t, name='globalAlert', interface='eth0', caller_uid=0, caller_pid=0, callbacks=n)
              for n, t in [(1,60),(2,160)]]
    write(root, 'probe.jsonl', sorted(probe, key=lambda r:r['time_ns']), True)
    identity = dict(event='identity', nonce=nonce, pid=6000, uid=10096,
                    status='Uid:\t10096\t10096\t10096\t10096\nGid:\t10096\t10096\t10096\t10096\nCapEff:\t0000000000000000\n',
                    cgroup='0::/royd/init\n')
    write(root, 'denied.jsonl', [identity]+[dict(event=k, nonce=nonce, pid=6000, uid=10096,
                  exception='java.lang.SecurityException') for k in ['denied-arm','denied-listener']], True)
    fields = dict(skbs=0, segments=0, gso_skbs=0, raw_bytes=0, other_ip_skbs=0, errors=0)
    def snapshot(packets):
        return dict(ifindex=2, map_id=17, production_links=[4,5], query=[[4,6],[5,7]],
                    counters=[packets,packets*1228]*2,
                    observed=[dict(fields, skbs=packets, segments=packets, raw_bytes=packets*1242) for _ in range(2)],
                    tcp=[[],[]])
    receipts = [dict(event='ready', address='172.17.0.1:9000', nonce=nonce)]
    packets = 0
    samples = [snapshot(0)]
    for phase, count in enumerate([256,1,256,256,256,1], 1):
        write(root, f'observer/p{phase}-before.json', snapshot(packets))
        packets += count
        write(root, f'observer/p{phase}-after.json', snapshot(packets))
        samples.append(snapshot(packets))
        local = f'172.17.0.2:{5000+phase}'
        write(root, f'worker-{phase}.log', [dict(event='ready', uid=1000, gid=1000, pid=100+phase,
              cap_eff='0', cgroup='0::/royd/init\n'), dict(event='complete', uid=1000, phase=phase,
              packets=count, payload_bytes=count*1200, segmented=False, loopback=False, raw=False,
              start_ns=1, end_ns=2, local=local, remote='172.17.0.1:9000')], True)
        receipts.append(dict(event='complete', phase=phase, uid=1000, packets=count,
                             payload_bytes=count*1200, segmented=False, peer=local))
    write(root, 'fixture.log', receipts, True)
    def state(generation, amount, committed):
        return dict(original, generation=generation, bytes=amount, committed=committed)
    windows = []
    before = [original, state(4,2097152,1), state(5,628737,1), state(6,1257472,1)]
    for label, seq, index, amount, prior in zip(['first','old','replacement','second'],[3,6,8,10],[0,2,3,4],
                                               [628737,628737,1257472,628737],before):
        windows.append(dict(label=label, bytes=amount, command=commands[seq], state_before=prior,
             state_after=state(prior['generation']+1,amount,prior['committed']),
             baseline_before=samples[index], baseline_after=samples[index]))
    write(root, 'windows.json', windows)
    for name, seq, phase, callbacks in [('first-below',4,1,0),('first-crossed',5,2,1),('old-below',7,3,1),
                                        ('replacement-below',9,4,1),('second-below',11,5,1),('second-crossed',12,6,2)]:
        write(root, name+'-quiet.json', dict(start_ns=1, end_ns=1500000001, seconds=1.5,
                                            callbacks=callbacks, reply=commands[seq], counters=samples[phase]))
    write(root, 'first-crossed-framework.json', state(4,2097152,1))
    write(root, 'second-crossed-framework.json', state(8,2097152,2))


class AlertAssessmentTest(unittest.TestCase):
    def test_full_witness(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); case(root)
            self.assertEqual(assess(root)['callbacks'], 2)

    def test_rejects_false_or_incomplete_witnesses(self):
        mutations = {
            'wrong-caller': ('probe.jsonl', lambda r:r[0].update(uid=1000), True),
            'nonroot-callback': ('probe.jsonl', lambda r:next(v for v in r if v['event']=='callback').update(caller_uid=10096), True),
            'wrong-oneway-pid': ('probe.jsonl', lambda r:next(v for v in r if v['event']=='callback').update(caller_pid=200), True),
            'wrong-interface': ('probe.jsonl', lambda r:next(v for v in r if v['event']=='callback').update(interface='lo'), True),
            'premature-callback': ('probe.jsonl', lambda r:next(v for v in r if v['event']=='callback').update(time_ns=40), True),
            'duplicate-callback': ('probe.jsonl', lambda r:r.append(next(v for v in r if v['event']=='callback').copy()), True),
            'missing-callback': ('probe.jsonl', lambda r:r.remove(next(v for v in r if v['event']=='callback')), True),
            'wrong-errno': ('probe.jsonl', lambda r:next(v for v in r if v.get('operation')=='invalid').update(error_code=1), True),
            'capability-grant': ('denied.jsonl', lambda r:r[0].update(status=r[0]['status'].replace('0000000000000000','0000000000000001')), True),
            'generic-denial': ('denied.jsonl', lambda r:r[1].update(exception='java.io.IOException'), True),
            'lost-UID': ('denied.jsonl', lambda r:r[0].update(uid=0), True),
            'stale-window': ('windows.json', lambda r:r[2]['state_after'].update(generation=5), False),
            'wrong-threshold': ('windows.json', lambda r:r[0].update(bytes=628736), False),
            'ambiguous-baseline': ('windows.json', lambda r:r[0]['baseline_after']['counters'].__setitem__(0,1), False),
            'background-IP': ('first-below-quiet.json', lambda r:r['counters']['counters'].__setitem__(0,257), False),
            'post-cross-background-IP': ('second-crossed-quiet.json', lambda r:r['counters']['counters'].__setitem__(0,1027), False),
            'short-window': ('first-below-quiet.json', lambda r:r.update(end_ns=100), False),
            'no-framework-rearm': ('first-crossed-framework.json', lambda r:r.update(generation=3), False),
            'wrong-framework-budget': ('second-crossed-framework.json', lambda r:r.update(bytes=628737), False),
            'source-fault': ('first-crossed-framework.json', lambda r:r.update(error=5), False),
            'missing-packet': ('worker-2.log', lambda r:r[1].update(packets=0), True),
            'lost-product-map': ('observer/p3-after.json', lambda r:r.update(map_id=18), False),
            'missing-receipt': ('fixture.log', lambda r:r.pop(), True),
        }
        for name, (file, mutate, jsonl) in mutations.items():
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                root = Path(directory); case(root)
                data = [json.loads(line) for line in (root/file).read_text().splitlines()] if jsonl else json.loads((root/file).read_text())
                mutate(data); write(root,file,data,jsonl)
                with self.assertRaises(AssertionError): assess(root)


if __name__ == '__main__':
    unittest.main()
