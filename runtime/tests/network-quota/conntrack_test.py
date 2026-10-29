import ipaddress
import struct
import socket
import unittest
from pathlib import Path
from unittest.mock import patch
from conntrack import attributes, entry, messages, dump


def attr(kind,data):
    size=len(data)+4
    return struct.pack('=HH',size,kind)+data+b'\0'*((-size)%4)


def endpoint(source,destination,sport,dport):
    ip=attr(1,ipaddress.ip_address(source).packed)+attr(2,ipaddress.ip_address(destination).packed)
    proto=attr(1,b'\x06')+attr(2,struct.pack('!H',sport))+attr(3,struct.pack('!H',dport))
    return attr(1,ip)+attr(2,proto)


def record(state=3):
    return b'\x02\0\0\0'+attr(1,endpoint('10.254.0.2','1.1.1.1',40000,443))+\
        attr(2,endpoint('1.1.1.1','172.17.0.2',443,40000))+attr(3,struct.pack('!I',30))+\
        attr(4,attr(1,attr(1,bytes([state]))))+attr(7,struct.pack('!I',432000))+attr(12,struct.pack('!I',42))


def message(kind=0x100,payload=None,flags=2,sequence=99,pid=500):
    payload=record() if payload is None else payload
    return struct.pack('=IHHII',len(payload)+16,kind,flags,sequence,pid)+payload


class Conntrack(unittest.TestCase):
    def test_actual_nested_tuple_state_and_timeout_fields(self):
        for state in range(10):
            r=entry(record(state));self.assertEqual((r['state'],r['id'],r['timeout_seconds']),(state,42,432000))
            self.assertEqual(r['original']['source'],'10.254.0.2');self.assertEqual(r['reply']['destination'],'172.17.0.2')

    def test_duplicate_bad_padding_and_short_attributes_fail(self):
        for data in (b'x',attr(1,b'x')+attr(1,b'y'),attr(1,b'x')[:-1],struct.pack('=HH',3,1)):
            with self.assertRaises(ValueError):attributes(data)

    def test_multipart_done_and_identity_requirements(self):
        rows,done=messages(message()+message(3,struct.pack('=i',0)),99,500)
        self.assertEqual(len(rows),1);self.assertTrue(done)
        seen=set();self.assertEqual(len(messages(message(flags=34),99,500,seen)[0]),1);self.assertEqual(seen,{34})
        for wire in (message(sequence=98),message(pid=501),message(flags=18),message(flags=50),message(flags=0),
                     message(kind=2,payload=b'\0'*20),message(3,struct.pack('=i',-5)),message()[:-1],
                     message(3,struct.pack('=i',0))+message()):
            with self.assertRaises(ValueError):messages(wire,99,500)

    def test_matching_kernel_error_preserves_real_errno(self):
        echo=struct.pack('=IHHII',20,0x101,0x301,99,500)
        with self.assertRaisesRegex(ValueError,'errno 1'):
            messages(message(2,struct.pack('=i',-1)+echo,flags=0),99,500)

    def test_host_and_android_namespaces_are_refused_before_socket(self):
        for actual in ('host','android'):
            with patch('conntrack.os.readlink',return_value=actual),patch('conntrack.socket.socket') as create,\
                    self.assertRaisesRegex(ValueError,'owned gateway'):
                dump(actual,['host','android'])
            create.assert_not_called()

    def test_missing_handler_is_not_autoloaded_or_reported_empty(self):
        with patch('conntrack.os.readlink',return_value='gateway'),patch.object(Path,'is_dir',return_value=False),\
                patch('conntrack.socket.socket') as create,self.assertRaisesRegex(ValueError,'existing conntrack'):
            dump('gateway',['host','android'])
        create.assert_not_called()

    def test_real_dump_request_is_get_only_with_complete_kernel_reply(self):
        with patch('conntrack.os.readlink',return_value='gateway'),patch.object(Path,'is_dir',return_value=True),\
                patch('conntrack.socket.socket') as create,patch('conntrack.secrets.randbits',return_value=99):
            reader=create.return_value.__enter__.return_value;reader.getsockname.return_value=(500,0)
            reader.sendto.side_effect=lambda data,address:len(data)
            reader.recvmsg.return_value=(message(flags=34)+message(3,struct.pack('=i',0)),[],0,(0,0))
            result=dump('gateway',['android','host'])
            self.assertEqual(result['reply_flags'],[2,34]);self.assertEqual(len(result['entries']),1)
            wire=reader.sendto.call_args.args[0]
            self.assertEqual(struct.unpack('=IHHII',wire[:16]),(20,0x101,0x301,99,500))
            self.assertEqual(wire[16:],b'\x02\0\0\0');reader.bind.assert_called_once_with((0,0))
            create.assert_called_once_with(socket.AF_NETLINK,socket.SOCK_RAW,12)
            for flags in (socket.MSG_TRUNC,socket.MSG_CTRUNC):
                reader.recvmsg.return_value=(b'',[],flags,(0,0))
                with self.assertRaisesRegex(ValueError,'sender/truncation'):dump('gateway',['android','host'])


if __name__ == '__main__':unittest.main()
