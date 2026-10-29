import json
import os
import subprocess
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from unittest.mock import Mock
from socket_census import endpoint,parse,owners,observe
from diagnose_tcp import analyse,Probe

HEADER='  sl  local_address rem_address st tx_queue rx_queue tr tm->when retrnsmt uid timeout inode\n'


class Tables(unittest.TestCase):
    def test_ipv4_and_mapped_ipv6_endpoints(self):
        self.assertEqual(endpoint('0200FE0A:999E',4),dict(address='10.254.0.2',port=39326))
        self.assertEqual(endpoint('0000000000000000FFFF00000200FE0A:999E',6),dict(address='10.254.0.2',port=39326))

    def test_live_and_inode_zero_timewait_are_distinct(self):
        row=' 0: 0200FE0A:999E 719AFA8E:01BB 01 00000000:00000004 02:00000010 00000002 10063 0 42\n'
        live=parse(HEADER+row,4)[0]
        self.assertEqual((live['uid'],live['inode'],live['state'],live['rx_queue'],live['retransmits']),(10063,42,1,4,2))
        waiting=parse(HEADER+row.replace('01 00000000','06 00000000').replace('10063 0 42','0 0 0'),4)[0]
        self.assertEqual((waiting['inode'],waiting['state']),(0,6))
        for bad in ('',HEADER+'short\n',HEADER+row.replace('999E','9')):
            with self.assertRaises(ValueError):parse(bad,4)

    def test_host_namespace_refused_before_table_reads(self):
        with patch('socket_census.os.readlink',return_value='host'):
            with self.assertRaisesRegex(ValueError,'private network'):observe(Path('/unused'),'host',2,10)


class FdOwners(unittest.TestCase):
    def files(self,root,namespace='private'):
        p=root/'123';(p/'ns').mkdir(parents=True);(p/'fd').mkdir()
        (p/'ns/net').symlink_to(namespace);(p/'fd/7').symlink_to('socket:[42]')
        (p/'stat').write_text('123 (name) '+' '.join(['S']+['0']*18+['999'])+'\n')
        (p/'status').write_text('Uid:\t1000\t1000\t1000\t1000\n')
        (p/'cmdline').write_bytes(b'com.android.webview:worker\0password-canary\0')
        (p/'cgroup').write_text('0::/royd/uid_1000/pid_123\n')

    def test_actual_fd_owner_can_differ_from_socket_uid_without_argv_payload(self):
        with tempfile.TemporaryDirectory() as name:
            root=Path(name);self.files(root)
            result=owners([dict(inode=42,uid=10063)],'private',root)
        self.assertEqual(result['processes'][0]['uids'],[1000]*4)
        self.assertEqual(result['processes'][0]['sockets'],[dict(fd=7,inode=42)])
        self.assertNotIn('password-canary',json.dumps(result))

    def test_other_namespace_and_inode_zero_do_not_get_false_owners(self):
        with tempfile.TemporaryDirectory() as name:
            root=Path(name);self.files(root,'foreign')
            self.assertEqual(owners([dict(inode=42,uid=10063)],'private',root)['processes'],[])
            self.assertEqual(owners([dict(inode=0,uid=0)],'foreign',root)['processes'],[])

    def test_pid_reuse_during_fd_scan_is_a_failure(self):
        with tempfile.TemporaryDirectory() as name:
            root=Path(name);self.files(root)
            a=dict(pid=123,start_ticks=1,uids=[1000]*4);b=dict(a,start_ticks=2)
            with patch('socket_census.process_identity',side_effect=[a,b]),self.assertRaisesRegex(ValueError,'identity raced'):
                owners([dict(inode=42,uid=10063)],'private',root)


class Correlation(unittest.TestCase):
    def test_tuple_history_keeps_different_inodes_and_does_not_invent_late_owner(self):
        with tempfile.TemporaryDirectory() as name:
            root=Path(name);(root/'headers').mkdir();(root/'census').mkdir()
            packet=dict(protocol=6,direction='ingress',tcp_flags=17,tcp_sequence=200,tcp_acknowledgement=300,
                        destination='10.254.0.2',destination_port=1,source='1.1.1.1',source_port=443,received_monotonic_ns=100)
            (root/'headers/headers.jsonl').write_text(json.dumps(packet)+'\n')
            socket=dict(local=dict(address='10.254.0.2',port=1),remote=dict(address='1.1.1.1',port=443),uid=10063,inode=42,state=1)
            rows=[dict(sequence=1,start_ns=1,end_ns=2,sockets=[socket],owners=None),
                  dict(sequence=2,start_ns=4,end_ns=5,sockets=[dict(socket,inode=43,uid=10064)],owners=None)]
            (root/'census/samples.jsonl').write_text(''.join(json.dumps(r)+'\n' for r in rows))
            result=analyse(root)['fin_flows'][0]
        self.assertEqual(result['observed_fd_holders'],[])
        self.assertEqual([r['sockets'][0]['inode'] for r in result['socket_history']],[42,43])


class Capture(unittest.TestCase):
    def test_diagnostic_query_failure_still_retains_full_log_and_all_resources(self):
        with tempfile.TemporaryDirectory() as name,patch.dict(os.environ,ROYD_QUOTA_OUTPUT_DIR=name+'/out',
                ROYD_QUOTA_NETWORK_MODE='isolated',ROYD_QUOTA_PACKET_HEADERS='1'):
            probe=Probe();probe.created=True;probe.cid='owned';probe.boot_ready=True
            probe.owner=lambda:None;probe.link=Mock();probe.link.frozen=None
            calls=[]
            def run(argv,*args,**kwargs):
                calls.append(list(map(str,argv)))
                return subprocess.CompletedProcess(argv,1 if argv[:2]==['docker','exec'] else 0,'')
            probe.run=run
            def failed(*args):raise ValueError('diagnostic query failed')
            probe.dx=failed;probe.finish()
            self.assertTrue(any(v[0].endswith('container-evidence.sh') for v in calls))
            self.assertFalse(any(v[:2]==['docker','rm'] for v in calls))
            self.assertEqual(probe.manifest['CAPTURE_STATUS'],'fail')
            probe.link.cleanup.assert_not_called()

    def test_failed_observer_does_not_allow_owned_namespace_deletion(self):
        with tempfile.TemporaryDirectory() as name,patch.dict(os.environ,ROYD_QUOTA_OUTPUT_DIR=name+'/out',
                ROYD_QUOTA_NETWORK_MODE='isolated',ROYD_QUOTA_PACKET_HEADERS='1'):
            probe=Probe();probe.created=True;probe.cid='owned';probe.owner=lambda:None
            probe.link=Mock();probe.link.frozen=None
            (probe.out/'headers').mkdir();child=Mock();child.wait.return_value=1;child.poll.return_value=1
            probe.monitors={'headers':child};calls=[]
            def run(argv,*args,**kwargs):
                calls.append(list(map(str,argv)))
                return subprocess.CompletedProcess(argv,1 if argv[:2]==['docker','exec'] else 0,'')
            probe.run=run;probe.finish()
            self.assertEqual(probe.manifest['HEADERS_STATUS'],'fail')
            self.assertFalse(any(v[:2]==['docker','rm'] for v in calls))
            probe.link.cleanup.assert_not_called()


if __name__=='__main__':unittest.main()
