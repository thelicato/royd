import copy
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch, Mock
from preparation import external, Window, replay, observe, replay_for_scope, Gateway
from run import Trial


def source():
    return dict(ifindex=2,map_id=5,production_links=[8,9],query=[[8,10],[9,11]],counters=[0,0,0,0])


def socket_row(state=1,local='10.254.0.2',remote='1.1.1.1',inode=0):
    return dict(state=state,inode=inode,uid=0,local=dict(address=local,port=40000),remote=dict(address=remote,port=443))


def sample(n, sockets=None, value=None):
    value=value or source()
    return dict(sequence=n+1,start_ns=n*1_000_000_000+1,end_ns=n*1_000_000_000+2,
                before=copy.deepcopy(value),after=copy.deepcopy(value),sockets=sockets or [],
                conntrack=dict(namespace="gateway",entries=[],datagrams=1,bytes=20,reply_flags=[2]))


class Drain(unittest.TestCase):
    def test_inode_zero_closing_states_are_blockers(self):
        for state in (1,2,3,4,5,6,7,8,9,11,12):
            self.assertEqual(external([socket_row(state)]),[socket_row(state)])
        self.assertEqual(external([socket_row(10),socket_row(local='127.0.0.1',remote='127.0.0.2')]),[])
        self.assertTrue(external([socket_row(local='::1',remote='2001:db8::1')]))

    def test_ten_seconds_and_eleven_observations_required(self):
        w=Window(source(),'gateway')
        for n in range(10):self.assertFalse(w.add(sample(n)))
        self.assertTrue(w.add(sample(10)))

    def test_late_socket_or_packet_resets_window(self):
        for change in ('socket','packet'):
            w=Window(source(),'gateway')
            for n in range(9):self.assertFalse(w.add(sample(n)))
            value=source()
            if change=='packet':value['counters']=[1,52,0,0]
            self.assertFalse(w.add(sample(9,[socket_row(9)] if change=='socket' else [],value)))
            for n in range(10,20):self.assertFalse(w.add(sample(n,value=value)))
            self.assertTrue(w.add(sample(20,value=value)))

    def test_read_gap_cannot_manufacture_quiet_time(self):
        w=Window(source(),'gateway');self.assertFalse(w.add(sample(0)))
        self.assertFalse(w.add(sample(20)))
        for n in range(21,31):self.assertFalse(w.add(sample(n)))
        self.assertTrue(w.add(sample(31)))

    def test_changed_source_or_regression_fails_instead_of_reset(self):
        for key,value in [('ifindex',3),('map_id',6),('query',[[8],[9]]),('production_links',[12,13])]:
            other=source();other[key]=value
            with self.assertRaisesRegex(ValueError,'identity changed'):Window(source(),'gateway').add(sample(0,value=other))
        w=Window(source(),'gateway');higher=source();higher['counters']=[1,52,0,0];w.add(sample(0,value=higher))
        with self.assertRaisesRegex(ValueError,'regressed'):w.add(sample(1))

    def test_noise_during_bracketing_reads_is_not_quiet(self):
        w=Window(source(),'gateway');row=sample(0);row['after']['counters']=[0,0,1,52]
        self.assertFalse(w.add(row));self.assertIsNone(w.since)

    def test_gateway_flow_blocks_after_local_socket_disappears(self):
        w=Window(source(),'gateway')
        for n in range(20):
            row=sample(n);row['conntrack']['entries']=[dict(state=3)]
            self.assertFalse(w.add(row));self.assertIsNone(w.since)
        for n in range(20,30):self.assertFalse(w.add(sample(n)))
        self.assertTrue(w.add(sample(30)))

    def test_incomplete_or_foreign_conntrack_cannot_become_empty_success(self):
        for key,value in [('namespace','host'),('datagrams',0),('bytes',0),('reply_flags',[18])]:
            row=sample(0);row['conntrack'][key]=value
            with self.assertRaisesRegex(ValueError,'incomplete gateway'):Window(source(),'gateway').add(row)

    def test_host_namespace_is_refused_without_accounting_access(self):
        with patch('preparation.os.readlink',return_value='host'),self.assertRaisesRegex(ValueError,'private'):
            observe(Path('/unused'),'host',10,Path('/unused'),Path('/unused'),source(),30,Path('/unused'),'gateway')

    def test_deadline_emits_failure_without_waiting_for_a_quieter_retry(self):
        with tempfile.TemporaryDirectory() as name,patch('preparation.os.readlink',side_effect=['private','host','host']),\
                patch('preparation.socket.if_nametoindex',return_value=2),\
                patch('preparation.Gateway') as factory,\
                patch('preparation.time.monotonic_ns',side_effect=[1,31_000_000_001,31_000_000_002]):
            factory.return_value.__enter__.return_value.namespace='gateway'
            p=Path(name);self.assertEqual(observe(p,'private',10,Path('/unused'),Path('/unused'),source(),30,Path('/unused'),'gateway'),1)
            result=json.loads((p/'result.json').read_text())
            self.assertEqual(result['status'],'fail');self.assertIn('deadline exceeded',result['errors'][0])


class Saved(unittest.TestCase):
    def test_new_isolated_scope_cannot_omit_preparation(self):
        with tempfile.TemporaryDirectory() as name:
            p=Path(name)
            replay_for_scope(p,{})  # Retained historical evidence keeps its original scope.
            with self.assertRaises(FileNotFoundError):
                replay_for_scope(p,dict(preparation_required=True,network_mode='isolated'))
            with self.assertRaisesRegex(ValueError,'mode changed'):
                replay_for_scope(p,dict(preparation_required=False,network_mode='isolated'))
            (p/'manifest.env').write_text('ROYD_QUOTA_EVIDENCE_FORMAT=5\n')
            with self.assertRaisesRegex(ValueError,'missing required'):
                replay_for_scope(p,{})

    def test_replay_rejects_incomplete_changed_or_unquiet_evidence(self):
        with tempfile.TemporaryDirectory() as name:
            p=Path(name)
            ready=dict(format=2,namespace='private',gateway_namespace='gateway',initial=source(),quiet_seconds=10,deadline_seconds=30,opened_ns=0)
            rows=[sample(n) for n in range(11)]
            result=dict(status='pass',errors=[],namespace='private',ifindex=2,samples=11,quiet_since_ns=2,closed_ns=11_000_000_000)
            def save():
                for name,value in [('ready',ready),('result',result)]: (p/(name+'.json')).write_text(json.dumps(value))
                (p/'samples.jsonl').write_text(''.join(json.dumps(r)+'\n' for r in rows))
            save();self.assertEqual(replay(p,source())['status'],'pass')
            for mutate in (lambda:rows[5]['sockets'].append(socket_row(9)),lambda:rows.pop(),
                           lambda:result.update(namespace='foreign'),lambda:ready['initial'].update(map_id=7)):
                original=copy.deepcopy((ready,rows,result));mutate();save()
                with self.assertRaises((ValueError,KeyError)):replay(p,source())
                ready,rows,result=original


class GatewayIdentity(unittest.TestCase):
    def test_host_namespace_is_refused_before_opening_a_descriptor(self):
        with patch('preparation.os.open') as opened,self.assertRaisesRegex(ValueError,'private gateway'):
            with Gateway('/unused','host','android','host'):pass
        opened.assert_not_called()

    def test_changed_pinned_descriptor_closes_and_fails(self):
        with patch('preparation.os.open',return_value=55),patch('preparation.os.close') as closed,\
                patch('preparation.os.readlink',side_effect=['gateway','foreign']),\
                self.assertRaisesRegex(ValueError,'identity changed'):
            with Gateway('/private','gateway','android','host'):pass
        closed.assert_called_once_with(55)

    def test_child_uses_only_pinned_namespace_and_read_failure_is_not_empty(self):
        with patch('preparation.os.open',return_value=55),patch('preparation.os.close') as closed,\
                patch('preparation.os.readlink',return_value='gateway'),patch('preparation.subprocess.run') as run:
            run.return_value=Mock(returncode=1,stderr='real kernel read failure')
            with Gateway('/private','gateway','android','host') as gateway:
                with self.assertRaisesRegex(ValueError,'read failed'):gateway.read()
            self.assertEqual(run.call_args.args[0][1],'--net=/proc/self/fd/55')
            self.assertEqual(run.call_args.kwargs['pass_fds'],(55,))
        closed.assert_called_once_with(55)


class Integration(unittest.TestCase):
    def test_isolated_mode_requires_new_stage_but_bridge_keeps_old_scope(self):
        for mode in ('bridge','isolated'):
            with tempfile.TemporaryDirectory() as name,patch.dict(os.environ,ROYD_QUOTA_OUTPUT_DIR=name+'/out',
                    ROYD_QUOTA_NETWORK_MODE=mode,ROYD_QUOTA_PACKET_HEADERS='1'):
                t=Trial()
                self.assertEqual('PREPARATION_STATUS' in t.manifest,mode=='isolated')
                if mode=='isolated':self.assertIn('PREPARATION_STATUS',t.extra_required)
                else:
                    t.run=lambda *args,**kwargs:self.fail('bridge preparation must not run')
                    t.prepare_measurement()

    def test_failed_preparation_is_not_reported_passed_or_retried(self):
        with tempfile.TemporaryDirectory() as name,patch.dict(os.environ,ROYD_QUOTA_OUTPUT_DIR=name+'/out',
                ROYD_QUOTA_NETWORK_MODE='isolated',ROYD_QUOTA_PACKET_HEADERS='1'):
            t=Trial();t.namespace_owner=lambda:None;t.host_pid=123;t.namespace='private';t.bpf_root='/private'
            calls=[]
            def failed(*args,**kwargs):calls.append(args);raise RuntimeError('deadline')
            t.run=failed;t.link.holders['gateway']=dict(pid=456,namespace='gateway');t.link.owner=lambda role:None
            with self.assertRaises(RuntimeError):t.prepare_measurement()
            self.assertEqual(len(calls),1);self.assertEqual(t.manifest['PREPARATION_STATUS'],'fail')


if __name__ == '__main__':unittest.main()
