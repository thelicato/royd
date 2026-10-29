import json
import socket
import struct
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from packet_headers import metadata, timestamp, observe, SO_TIMESTAMPNS
import runner_test


def ipv4(payload, protocol=17, fragment=0, options=b''):
    size = 20+len(options)
    header = struct.pack('!BBHHHBBH4s4s', 0x40+size//4, 0, size+len(payload), 1, fragment,
                         64, protocol, 0, socket.inet_aton('172.17.0.2'), socket.inet_aton('1.1.1.1'))+options
    return b'\0'*12+b'\x08\x00'+header+payload


def udp(payload, source=40000, destination=53):
    return struct.pack('!4H', source, destination, len(payload)+8, 0)+payload


class Headers(unittest.TestCase):
    def test_dns_headers_options_and_no_payload_in_output(self):
        payload = struct.pack('!6H', 42, 0x100, 1, 0, 0, 0)+b'private-payload-canary'*100
        frame = ipv4(udp(payload), options=b'\1\1\1\1')
        value = metadata(frame[:128], len(frame))
        self.assertEqual(value['ip_bytes'], len(frame)-14)
        self.assertEqual((value['source_port'], value['destination_port']), (40000, 53))
        self.assertEqual(value['dns_header'], dict(id=42, flags=256, questions=1, answers=0, authority=0, additional=0))
        self.assertNotIn('private-payload', json.dumps(value))
        self.assertNotIn('payload', value)

    def test_tcp_ipv6_extensions_and_fragments(self):
        tcp = struct.pack('!HH', 50000, 443)+b'\0'*8+b'\x50\x12'+b'\0'*6
        value = metadata(ipv4(tcp, 6), 54)
        self.assertEqual((value['source_port'], value['tcp_flags']), (50000, 18))
        value = metadata(ipv4(udp(b'hello'), fragment=0x2000), 47)
        self.assertTrue(value['fragmented'])
        self.assertNotIn('source_port', value)
        v6 = b'\0'*12+b'\x86\xdd'+struct.pack('!IHBB16s16s', 6 << 28, 8, 44, 64,
            socket.inet_pton(socket.AF_INET6, 'fd00::1'), socket.inet_pton(socket.AF_INET6, 'fd00::2'))+b'\0'*8
        value = metadata(v6, len(v6))
        self.assertEqual((value['family'], value['protocol'], value['source']), (6, 44, 'fd00::1'))
        self.assertNotIn('source_port', value)

    def test_router_solicitation_identity_without_options_or_payload(self):
        frame = bytes.fromhex('33330000000246ee329f1b4486dd')+struct.pack('!IHBB16s16s',
            6 << 28, 16, 58, 255, socket.inet_pton(socket.AF_INET6, 'fe80::44ee:32ff:fe9f:1b44'),
            socket.inet_pton(socket.AF_INET6, 'ff02::2'))+bytes([133,0,0,0])+b'private-data'
        value = metadata(frame,len(frame))
        self.assertEqual((value['ethernet_source'],value['ethernet_destination']),
                         ('46:ee:32:9f:1b:44','33:33:00:00:00:02'))
        self.assertEqual((value['icmp_type'],value['icmp_code'],value['hop_limit']),(133,0,255))
        self.assertNotIn('private-data',json.dumps(value))
        for short in (frame[:55],frame[:57]):
            with self.assertRaisesRegex(ValueError,'short ICMP'):metadata(short,len(frame))
        # Extension headers do not imply that the following byte is an ICMP type.
        changed = bytearray(frame);changed[20] = 0
        self.assertNotIn('icmp_type',metadata(bytes(changed),len(changed)))

    def test_ipv4_icmp_and_fragments(self):
        frame = ipv4(bytes([3,3,0,0])+b'private-data',1)
        value = metadata(frame,len(frame))
        self.assertEqual((value['icmp_type'],value['icmp_code'],value['hop_limit']),(3,3,64))
        fragment = ipv4(bytes([3,3,0,0]),1,fragment=0x2000)
        self.assertNotIn('icmp_type',metadata(fragment,len(fragment)))

    def test_tcp_sequence_ack_and_cost_without_payload(self):
        tcp=struct.pack('!HHII',50000,443,0xfffffffe,42)+b'\x80\x11'+b'\0'*18+b'payload-canary'
        frame=ipv4(tcp,6);value=metadata(frame[:128],len(frame))
        self.assertEqual((value['tcp_sequence'],value['tcp_acknowledgement'],value['tcp_header_bytes']),
                         (0xfffffffe,42,32))
        self.assertEqual(value['tcp_payload_bytes'],len(b'payload-canary'))
        self.assertNotIn('payload-canary',json.dumps(value))
        for offset in (0x10,0xf0):
            bad=bytearray(frame);bad[46]=offset
            with self.assertRaisesRegex(ValueError,'TCP header length'):metadata(bytes(bad),len(bad))

    def test_malformed_lengths_and_truncated_headers_are_rejected(self):
        good = ipv4(udp(b'x'*20))
        bad = bytearray(good);bad[14] = 0x44
        bad_udp = bytearray(good);bad_udp[38:40] = b'\0\0'
        for data, size in [(good[:13], len(good)), (good[:33], len(good)), (bad, len(bad)),
                           (good, len(good)-1), (bad_udp, len(bad_udp)), (good[:40], len(good))]:
            with self.subTest(data=data), self.assertRaises(ValueError): metadata(data, size)

    def test_timestamp_integrity(self):
        value = [(socket.SOL_SOCKET, SO_TIMESTAMPNS, struct.pack('@ll', 123, 456))]
        self.assertEqual(timestamp(value, 0), 123000000456)
        for data, flags in [([], 0), (value*2, 0), (value, socket.MSG_CTRUNC),
                            ([(socket.SOL_SOCKET, SO_TIMESTAMPNS, b'x')], 0),
                            ([(socket.SOL_SOCKET, SO_TIMESTAMPNS, struct.pack('@ll', 1, 1000000000))], 0)]:
            with self.subTest(data=data), self.assertRaises(ValueError): timestamp(data, flags)

    def test_host_namespace_refused_before_socket_creation(self):
        with tempfile.TemporaryDirectory() as name, patch('packet_headers.os.readlink', return_value='same'), \
                patch('packet_headers.socket.socket') as create:
            with self.assertRaisesRegex(ValueError, 'private network namespace'):
                observe(Path(name), 'same', 2, 50)
            create.assert_not_called()

    def test_wrong_interface_refused_before_socket_creation(self):
        with tempfile.TemporaryDirectory() as name, patch('packet_headers.os.readlink', side_effect=['private', 'host']), \
                patch('packet_headers.socket.if_nametoindex', return_value=3), patch('packet_headers.socket.socket') as create:
            with self.assertRaisesRegex(ValueError, 'eth0 identity'):
                observe(Path(name), 'private', 2, 50)
            create.assert_not_called()

    def test_capture_loss_pending_frames_and_bound_fail_with_retained_metadata(self):
        frame = ipv4(udp(struct.pack('!6H', 42, 256, 1, 0, 0, 0)+b'payload-canary'*100))
        for packets, drops, bound in [(1, 0, 4096), (2, 1, 4096), (2, 0, 4096), (1, 0, 0)]:
            with self.subTest(packets=packets, drops=drops, bound=bound), tempfile.TemporaryDirectory() as name:
                directory = Path(name)
                calls = []
                class Receiver:
                    delivered = False
                    def __enter__(self): return self
                    def __exit__(self, *args): pass
                    def setsockopt(self, *args): calls.append(('option', *args))
                    def settimeout(self, value): pass
                    def setblocking(self, value): pass
                    def bind(self, address): calls.append(('bind', address))
                    def recvmsg_into(self, buffers, ancillary_size, flags):
                        if self.delivered: raise BlockingIOError()
                        self.delivered = True
                        buffers[0][:] = frame[:128]
                        (directory/'stop').touch()
                        return len(frame), [(socket.SOL_SOCKET, SO_TIMESTAMPNS, struct.pack('@ll', 123, 456))], \
                            socket.MSG_TRUNC, ('eth0', 0x800, 0, 1, b'')
                    def getsockopt(self, *args): return struct.pack('=II', packets, drops)
                with patch('packet_headers.os.readlink', side_effect=['private', 'host']), \
                        patch('packet_headers.socket.if_nametoindex', return_value=2), \
                        patch('packet_headers.socket.socket', return_value=Receiver()) as create, \
                        patch('packet_headers.MAX_FRAMES', bound):
                    status = observe(directory, 'private', 2, 50)
                self.assertEqual(status, 0 if packets == 1 and drops == 0 and bound else 1)
                result = json.loads((directory/'result.json').read_text())
                self.assertEqual(result['status'], 'pass' if status == 0 else 'fail')
                self.assertNotIn('payload-canary', (directory/'headers.jsonl').read_text())
                create.assert_called_once_with(socket.AF_PACKET, socket.SOCK_RAW, 0)
                self.assertEqual(calls, [('option', socket.SOL_SOCKET, SO_TIMESTAMPNS, 1), ('bind', ('eth0', 3))])


class HeaderCleanup(unittest.TestCase):
    setUp = runner_test.Lifecycle.setUp
    tearDown = runner_test.Lifecycle.tearDown
    configure = runner_test.Lifecycle.configure
    def test_header_capture_failure_prevents_cleanup(self):
        t = self.configure()
        t.headers_enabled = True
        t.manifest['PACKET_HEADERS_STATUS'] = 'fail'
        t.header_process = type('Process', (), dict(poll=lambda _: 0))()
        def fail(): raise ValueError('lost header capture')
        t.stop_headers = fail
        t.finish()
        self.assertEqual(t.manifest['CAPTURE_STATUS'], 'fail')
        self.assertFalse(any(isinstance(x, list) and x[:2] == ['docker', 'rm'] for x in self.calls))


if __name__ == '__main__': unittest.main()
