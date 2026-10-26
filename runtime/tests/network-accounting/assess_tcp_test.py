import copy
import unittest
from assess_tcp import assess, direction, payload_hash, STREAM_BYTES


def records(source, destination, source_port, destination_port):
    base = 0xffffffe0
    def row(sequence, length, tcp_len=32, flags=16, segmented=False):
        return dict(skb_len=14+20+tcp_len+length, ip_len=20, ip_total=20+tcp_len+length,
                    tcp_len=tcp_len, sequence=sequence % (1 << 32), gso_size=1448 if segmented else 0,
                    gso_segs=23 if segmented else 1, flags=flags, source=source, destination=destination,
                    source_port=source_port, destination_port=destination_port)
    result = [row(base, 0, tcp_len=40, flags=2)]
    result += [row(base+1+offset, 32768, segmented=True) for offset in range(0, STREAM_BYTES, 32768)]
    result += [row(base+1+STREAM_BYTES, 0, flags=17), row(base+2+STREAM_BYTES, 0)]
    return result


class TCPAccountingTest(unittest.TestCase):
    def case(self, phase=6):
        fixture = dict(tcp_address='172.17.0.1:9000', nonce='31323334353637383930616263646566')
        observation = dict(skbs=0, segments=0, gso_skbs=0, raw_bytes=0, other_ip_skbs=0, errors=0)
        before = dict(ifindex=2, map_id=17, production_links=[4, 5], query=[[4, 6], [5, 7]],
                      counters=[0]*4, observed=[observation.copy(), observation.copy()], tcp=[[], []])
        after = copy.deepcopy(before)
        workers, receipts = [], []
        uids = [1000] if phase == 6 else [0, 1000]
        for uid in uids:
            port = 12000+uid
            local = f'172.17.0.2:{port}'
            after['tcp'][0] += records(0xac110001, 0xac110002, 9000, port)
            after['tcp'][1] += records(0xac110002, 0xac110001, port, 9000)
            hashes = {key: payload_hash(fixture['nonce'], phase, uid, reply)
                      for key, reply in (('upload_sha256', 0), ('download_sha256', 1))}
            ready = dict(event='ready', uid=uid, gid=uid, pid=52+uid, cgroup='0::/royd/init\n', cap_eff='0')
            done = dict(event='tcp-complete', uid=uid, phase=phase, payload_bytes=STREAM_BYTES,
                        start_ns=10, end_ns=20, local=local, remote=fixture['tcp_address'], **hashes)
            workers.append([ready, done])
            receipts.append(dict(event='tcp-complete', uid=uid, phase=phase, payload_bytes=STREAM_BYTES, peer=local, **hashes))
        # 32 payload skbs each split into23 segments, plus SYN/FIN/ACK.
        # Known stream1048576 plus736*52+60+52+52 header bytes.
        after['counters'] = [739*len(uids), 1087012*len(uids)]*2
        return before, after, workers, receipts, phase, fixture

    def test_known_totals_options_and_sequence_wrap(self):
        for phase in (6, 7):
            with self.subTest(phase=phase):
                result = assess(*self.case(phase))
                self.assertEqual(result['status'], 'pass')
                self.assertEqual(result['tcp_header_widths'], [32, 40])
                self.assertEqual(result['gso_skbs_per_direction'], [32 if phase == 6 else 64]*2)

    def test_padding_excluded(self):
        args = self.case()
        args[1]['tcp'][0][0]['skb_len'] += 12
        self.assertEqual(assess(*args)['status'], 'pass')

    def test_rejections(self):
        for name, mutate in {
            'lost-payload': lambda a: a[1]['tcp'][0].pop(1),
            'duplicate-payload': lambda a: a[1]['tcp'][1].append(copy.deepcopy(a[1]['tcp'][1][1])),
            'wrong-segment-count': lambda a: a[1]['tcp'][0][1].update(gso_segs=22),
            'wrong-segment-size': lambda a: a[1]['tcp'][1][1].update(gso_size=2000),
            'missing-MSS': lambda a: a[1]['tcp'][0][1].update(gso_size=0),
            'ledger-overflow': lambda a: a[1]['tcp'].__setitem__(0, a[1]['tcp'][0]*120),
            'missing-handshake': lambda a: a[1]['tcp'][0].pop(0),
            'missing-teardown': lambda a: a[1]['tcp'][1].pop(-2),
            'missing-ledger-direction': lambda a: a[1]['tcp'].pop(),
            'wrong-peer': lambda a: a[1]['tcp'][0][1].update(source=0xac110003),
            'header-corruption': lambda a: a[1]['tcp'][1][1].update(tcp_len=31),
            'reset': lambda a: a[1]['tcp'][0][1].update(flags=20),
            'under-count': lambda a: a[1]['counters'].__setitem__(1, 1087011),
            'missing-ACK-count': lambda a: a[1]['counters'].__setitem__(0, 738),
            'wrong-payload-digest': lambda a: a[3][0].update(upload_sha256='0'*64),
            'missing-receipt': lambda a: a[3].clear(),
            'wrong-UID': lambda a: a[2][0][0].update(uid=0),
            'capability-grant': lambda a: a[2][0][0].update(cap_eff='1'),
            'background-IP': lambda a: a[1]['observed'][0].update(other_ip_skbs=1),
            'observer-overflow-error': lambda a: a[1]['observed'][1].update(errors=1),
            'lost-production-link': lambda a: a[1].update(production_links=[4, 7]),
        }.items():
            with self.subTest(name=name):
                args = list(self.case())
                mutate(args)
                with self.assertRaises(AssertionError):
                    assess(*args)

    def test_no_gso_is_not_segmentation_evidence(self):
        rows = records(1, 2, 9000, 12000)
        for row in rows:
            row.update(gso_size=0, gso_segs=1)
        with self.assertRaisesRegex(AssertionError, 'no actual TCP segmentation'):
            direction(rows)

    def test_lost_prefix_and_non_overlapping_workers(self):
        args = list(self.case())
        args[0]['tcp'][0] = [copy.deepcopy(args[1]['tcp'][0][0])]
        args[1]['tcp'][0][0]['sequence'] ^= 1
        with self.assertRaisesRegex(AssertionError, 'ledger changed'):
            assess(*args)
        args = list(self.case(7))
        args[2][1][1].update(start_ns=21, end_ns=30)
        with self.assertRaisesRegex(AssertionError, 'did not overlap'):
            assess(*args)


if __name__ == '__main__':
    unittest.main()
