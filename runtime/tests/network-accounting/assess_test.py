import copy
import unittest
from assess import assess


class AccountingTest(unittest.TestCase):
    def case(self, kind='segmented'):
        segmented = kind in ('segmented', 'concurrent')
        loopback = kind == 'loopback'
        uids = [0, 1000] if kind == 'concurrent' else [0] if kind == 'raw' else [1000]
        count = 256 if segmented else 64
        packets = 0 if loopback else count * len(uids)
        fields = dict(skbs=0, segments=0, gso_skbs=0, raw_bytes=0, other_ip_skbs=0, errors=0)
        before = dict(ifindex=2, map_id=17, production_links=[4, 5], query=[[4, 6], [5, 7]],
                      counters=[0]*4, observed=[fields.copy(), fields.copy()])
        after = copy.deepcopy(before)
        after['counters'] = [packets, packets*1228]*2
        skbs = packets//8 if segmented else packets
        after['observed'] = [dict(skbs=skbs, segments=packets, gso_skbs=skbs if segmented else 0,
                                 raw_bytes=skbs*(9600+42) if segmented else skbs*1242,
                                 other_ip_skbs=0, errors=0) for _ in range(2)]
        workers, receipts = [], []
        for uid in uids:
            local = f'127.0.0.1:{12000+uid}' if loopback else f'172.17.0.2:{12000+uid}'
            ready = dict(event='ready', uid=uid, gid=uid, pid=52+uid, cap_eff='0', cgroup='0::/royd/init\n')
            done = dict(event='complete', uid=uid, phase=1, packets=count, payload_bytes=count*1200,
                        segmented=segmented, raw=kind == 'raw', loopback=loopback,
                        start_ns=10, end_ns=20, local=local, remote='127.0.0.1:9000' if loopback else '172.17.0.1:9000')
            workers.append([ready, done])
            if not loopback:
                receipts.append(dict(event='complete', phase=1, uid=uid, packets=count,
                                     payload_bytes=count*1200, segmented=segmented, peer=local))
        return before, after, workers, receipts, 1, kind

    def test_positive(self):
        for kind in ('raw', 'normal', 'segmented', 'concurrent', 'loopback'):
            with self.subTest(kind=kind):
                self.assertEqual(assess(*self.case(kind))['status'], 'pass')

    def test_rejections(self):
        for label, mutate in {
            'under-count': lambda a: a[1]['counters'].__setitem__(1, 77000),
            'duplicate-count': lambda a: a[1]['counters'].__setitem__(0, 512),
            'no-real-GSO': lambda a: a[1]['observed'][0].update(gso_skbs=0),
            'only-one-direction': lambda a: a[1]['observed'][1].update(gso_skbs=0),
            'missing-direction': lambda a: a[1]['observed'].pop(),
            'missing-both-directions': lambda a: a[1].update(observed=[]),
            'background': lambda a: a[1]['observed'][0].update(other_ip_skbs=1),
            'observer-error': lambda a: a[1]['observed'][1].update(errors=1),
            'no-receipt': lambda a: a[3].clear(),
            'wrong-peer': lambda a: a[3][0].update(peer='172.17.0.3:1'),
            'wrong-UID': lambda a: a[2][0][0].update(uid=0),
            'unexpected-capability': lambda a: a[2][0][0].update(cap_eff='0000000000000001'),
            'lost-private-map': lambda a: a[1].update(map_id=19),
            'changed-link': lambda a: a[1].update(production_links=[7, 8]),
            'changed-query': lambda a: a[1].update(query=[[4], [5]]),
        }.items():
            with self.subTest(label=label):
                args = list(self.case())
                mutate(args)
                with self.assertRaises(AssertionError):
                    assess(*args)

    def test_concurrency_and_loopback_controls(self):
        for label, kind, mutate in (
            ('serial-workers', 'concurrent', lambda a: a[2][1][1].update(start_ns=21, end_ns=30)),
            ('one-worker', 'concurrent', lambda a: a[2].pop()),
            ('same-UID', 'concurrent', lambda a: a[2][1][0].update(uid=0, gid=0)),
            ('wrong-loopback-peer', 'loopback', lambda a: a[2][0][1].update(remote='172.17.0.1:9000')),
            ('eth0-counted-loopback', 'loopback', lambda a: a[1].update(counters=[64, 78592]*2)),
            ('loopback-observed-on-eth0', 'loopback', lambda a: a[1]['observed'][0].update(skbs=1)),
        ):
            with self.subTest(label=label):
                args = list(self.case(kind))
                mutate(args)
                with self.assertRaises(AssertionError):
                    assess(*args)


if __name__ == '__main__':
    unittest.main()
