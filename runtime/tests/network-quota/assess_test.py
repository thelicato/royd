import copy
import hashlib
from pathlib import Path
import socket
import tempfile
import time
import unittest
from assess import assess_flow
from fixture import Fixture, IP_BYTES, decode, packet


def example(operation='send', passed=0, count=1):
    nonce = 'ab'*16
    ready = dict(uid=10096, pid=500, nonce=nonce, local='172.17.0.2:40000',
                 remote='172.17.0.1:50000', importance=300)
    initial = dict(ifindex=2, map_id=10, counters=[10, 12280, 20, 24560],
                   query=[[11, 12, 13, 14], [21, 22, 23, 24]],
                   production_links=[11, 21],
                   observed=[dict(skbs=0, segments=0, gso_skbs=0, raw_bytes=0,
                                  other_ip_skbs=0, errors=0) for _ in (0, 1)])
    before = dict(pre=copy.deepcopy(initial), post=copy.deepcopy(initial))
    before['post']['production_links'] = [13, 23]
    before['post']['quota'] = dict(present=True, map_id=50, drops_map_id=51,
                                  remaining=100 if passed == 0 else passed*IP_BYTES, limit=5000,
                                  generation=20, invalid=0, contention=0)
    after = copy.deepcopy(before)
    direction = 1 if operation == 'send' else 0
    for side in ('pre', 'post'):
        after[side]['counters'][direction*2] += count
        after[side]['counters'][direction*2+1] += count*IP_BYTES
        n = count if side == 'pre' else passed
        for key in ('skbs', 'segments'):
            after[side]['observed'][direction][key] += n
        after[side]['observed'][direction]['raw_bytes'] += n*(IP_BYTES+14)
    after['post']['quota']['remaining'] = 0
    app = dict(ready, step=1, op=operation, count=count,
               ready_ns=100, released_ns=200, finished_ns=300,
               send_successes=count if operation == 'send' else 0, send_enobufs=0,
               received=passed if operation == 'receive' else 0, receive_timeout=operation == 'receive')
    receipts = []
    for sequence in range(passed if operation == 'send' else count):
        kind = 1 if operation == 'send' else 2
        receipts.append(dict(event='receive' if operation == 'send' else 'push', uid=10096,
                             step=1, sequence=sequence, count=count, kind=kind, peer=ready['local'],
                             sha256=hashlib.sha256(packet(bytes.fromhex(nonce), 1, 10096, sequence, count, kind)).hexdigest()))
    return dict(uid=10096, step=1, op=operation, count=count, passed=passed, remaining=0,
                ready=ready, app=app, fixture=receipts, before=before, after=after)


class Assessment(unittest.TestCase):
    def test_allowed_and_denied_both_directions(self):
        for op in ('send', 'receive'):
            for count, passed in ((1, 1), (1, 0), (2, 0)):
                with self.subTest(op=op, passed=passed):
                    self.assertEqual(assess_flow(example(op, passed, count))['admitted'], passed)

    def test_timeout_is_insufficient_without_packets_at_pre_hook(self):
        value = example('receive', 0)
        value['after']['pre']['observed'][0]['skbs'] = 0
        with self.assertRaisesRegex(ValueError, 'pre skbs'):
            assess_flow(value)

    def test_blocked_packet_mutations_fail(self):
        changes = [
            lambda v: v['after']['post']['observed'][1].update(skbs=1),
            lambda v: v['after']['pre']['observed'][1].update(other_ip_skbs=1),
            lambda v: v['after']['pre']['observed'][1].update(errors=1),
            lambda v: v['after']['pre']['observed'][1].update(gso_skbs=1),
            lambda v: v['after']['pre']['counters'].__setitem__(3, 24560),
            lambda v: v['after']['post']['quota'].update(remaining=100),
            lambda v: v['after']['post']['quota'].update(generation=21),
            lambda v: v['after']['post']['quota'].update(contention=1),
            lambda v: v['before']['post']['quota'].update(remaining=1228),
            lambda v: v['app'].update(pid=501),
            lambda v: v['app'].update(uid=10097),
            lambda v: v['app'].update(importance=100),
            lambda v: v['after']['pre']['query'][1].reverse(),
            lambda v: v['after']['post'].update(map_id=100),
        ]
        for mutation in changes:
            value = example()
            mutation(value)
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                assess_flow(value)

    def test_receipt_and_application_mutations_fail(self):
        changes = [
            lambda v: v['fixture'].clear(),
            lambda v: v['fixture'][0].update(sha256='0'*64),
            lambda v: v['fixture'][0].update(peer='172.17.0.3:40000'),
            lambda v: v['fixture'][0].update(sequence=1),
            lambda v: v['app'].update(received=0),
            lambda v: v['app'].update(receive_timeout=False),
        ]
        for mutation in changes:
            value = example('receive', 1)
            mutation(value)
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                assess_flow(value)


class Packets(unittest.TestCase):
    def test_roundtrip_and_corruption(self):
        nonce = bytes(range(16))
        for uid in (1000, 10096, 10097):
            for kind in (1, 2):
                data = packet(nonce, 12, uid, 2, 3, kind)
                self.assertEqual(decode(data, nonce)['uid'], uid)
                for index in (0, 17, 21, 25, 29, 32, 1199):
                    bad = bytearray(data)
                    bad[index] ^= 128
                    with self.assertRaises(ValueError):
                        decode(bad, nonce)

    def test_owned_socket_receipt_and_no_automatic_echo(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = Fixture('127.0.0.1', Path(directory)/'fixture.jsonl')
            try:
                with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as client:
                    client.bind(('127.0.0.1', 0))
                    client.settimeout(.1)
                    fixture.register(10096, '%s:%s' % client.getsockname())
                    client.sendto(packet(fixture.nonce, 1, 10096, 0, 1, 1), fixture.socket.getsockname())
                    end = time.monotonic() + 2
                    while not fixture.records() and time.monotonic() < end:
                        time.sleep(.01)
                    self.assertEqual(len(fixture.records()), 1)
                    with self.assertRaises(socket.timeout):
                        client.recv(1201)
                    fixture.push(10096, 2, 1)
                    self.assertEqual(decode(client.recv(1201), fixture.nonce)['kind'], 2)
            finally:
                self.assertEqual(fixture.close()['final_drops'], 0)


if __name__ == '__main__': unittest.main()
