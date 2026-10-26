import copy
import unittest
from assess_policy import assess, PACKAGES


class PolicyAccountingTest(unittest.TestCase):
    def case(self, phase=10):
        role = (phase-8) % 2
        blocked = phase == 10
        enabled = phase in (10, 11)
        fields = dict(skbs=0, segments=0, gso_skbs=0, raw_bytes=0, other_ip_skbs=0, errors=0)
        before = dict(ifindex=2, map_id=17, production_links=[4, 5], query=[[4, 6], [5, 7]],
                      counters=[0]*4, observed=[fields.copy(), fields.copy()], tcp=[[], []])
        after = copy.deepcopy(before)
        after['counters'] = [64, 78592, 0 if blocked else 64, 0 if blocked else 78592]
        after['observed'] = [dict(skbs=n, segments=n, gso_skbs=0, raw_bytes=n*1242, other_ip_skbs=0, errors=0)
                             for n in (64, 0 if blocked else 64)]
        fixture = dict(address='172.17.0.1:9000', nonce='0'*32)
        ready = [dict(event='ready', uid=10096+i, gid=10096+i, pid=31+i, role=('target', 'control')[i],
                      importance=300, cap_eff='0', cgroup=f'0::/royd/uid_{10096+i}/pid_{31+i}\n',
                      nonce=fixture['nonce'], remote=fixture['address'], local=f'172.17.0.2:{12000+i}') for i in range(2)]
        selected = ready[role]
        app = dict(selected, event='policy-complete', phase=phase, start_ns=1, end_ns=2_000_000_001,
                   send_attempts=64, send_successes=0 if blocked else 64, send_eperm=64 if blocked else 0,
                   receive_packets=0 if blocked else 64, receive_timeout=blocked, denial='EPERM' if blocked else '')
        receipts = [dict(event='policy-push', phase=10, uid=10096, peer=ready[0]['local'], packets=64, payload_bytes=76800)]
        if not blocked:
            receipts += [dict(event='policy-receive', phase=phase, uid=selected['uid'], peer=selected['local'], sequence=i, payload_bytes=1200) for i in range(64)]
            receipts += [dict(event='policy-complete', phase=phase, uid=selected['uid'], peer=selected['local'], packets=64, payload_bytes=76800)]
        identity = f"{selected['pid']} {selected['uid']}\n"
        process = f"Uid:\t{selected['uid']}\t{selected['uid']}\t{selected['uid']}\t{selected['uid']}\nGid:\t{selected['uid']}\t{selected['uid']}\t{selected['uid']}\t{selected['uid']}\nCapEff:\t0000000000000000\n"
        def bpf(on):
            return ('current ownerMatch configuration: '+('6144 OEM_DENY_3_MATCH BACKGROUND_MATCH' if on else '4096 BACKGROUND_MATCH')+
                    '\nsUidOwnerMap:\n10096 BACKGROUND_MATCH'+(' OEM_DENY_3_MATCH' if on else '')+'\n10097 BACKGROUND_MATCH\nsUidPermissionMap:\n')
        rules = [package+(':'+('deny' if enabled and i == 0 else 'allow')) for i, package in enumerate(PACKAGES)]
        return [before, after, ready, app, receipts, phase, fixture, identity, selected['cgroup'], process,
                ['10 (SERVICE)']*2, 'chain:enabled' if enabled else 'chain:disabled', rules, bpf(enabled), bpf(False)]

    def test_all_six_phases(self):
        for phase in range(8, 14):
            with self.subTest(phase=phase):
                self.assertEqual(assess(*self.case(phase))['status'], 'pass')

    def test_rejections(self):
        for name, mutate in {
            'delivered-denied-inbound': lambda a: a[3].update(receive_packets=1),
            'egress-not-denied': lambda a: a[3].update(send_eperm=0),
            'generic-failure': lambda a: a[3].update(denial=''),
            'short-receive-window': lambda a: a[3].update(end_ns=99999),
            'inbound-not-accounted': lambda a: a[1]['counters'].__setitem__(0, 0),
            'denied-outbound-counted': lambda a: a[1]['counters'].__setitem__(2, 1),
            'denied-outbound-seen': lambda a: a[1]['observed'][1].update(skbs=1),
            'no-real-inbound': lambda a: a[1]['observed'][0].update(segments=0),
            'background-IP': lambda a: a[1]['observed'][0].update(other_ip_skbs=1),
            'unexpected-GSO': lambda a: a[1]['observed'][0].update(gso_skbs=1),
            'missing-push-receipt': lambda a: a[4].clear(),
            'target-reaches-fixture': lambda a: a[4].append(dict(event='policy-receive', phase=10)),
            'changed-process': lambda a: a[3].update(pid=99),
            'changed-socket': lambda a: a[3].update(local='172.17.0.2:9'),
            'capability-grant': lambda a: a[2][0].update(cap_eff='1'),
            'outside-UID-cgroup': lambda a: a.__setitem__(8, '0::/royd/init\n'),
            'foreground-control': lambda a: a.__setitem__(10, ['2 (TOP)']*2),
            'wrong-getter': lambda a: a[12].__setitem__(0, PACKAGES[0]+':allow'),
            'missing-deny-map': lambda a: a.__setitem__(13, a[14]),
            'unrelated-policy-change': lambda a: a.__setitem__(13, a[13].replace('6144', '6152')),
            'missing-map-section': lambda a: a.__setitem__(13, a[13].replace('sUidOwnerMap:', 'missing:')),
            'lost-production-map': lambda a: a[1].update(map_id=18),
        }.items():
            with self.subTest(name=name):
                args = self.case()
                mutate(args)
                with self.assertRaises(AssertionError):
                    assess(*args)

    def test_control_and_restoration_receipts(self):
        for phase in (8, 9, 11, 12, 13):
            with self.subTest(phase=phase):
                args = self.case(phase)
                args[4].pop()
                with self.assertRaises(AssertionError):
                    assess(*args)


if __name__ == '__main__':
    unittest.main()
