import copy,hashlib,os,runpy,sys,tempfile,unittest
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'network-quota'))
from fixture import packet
from assess_policy_restart import assess,assess_initial
from assess_policy_usage_test import case as usage_case


def case():
    old=usage_case();base=old['baseline'];base.update(operation='inspect')
    headroom=8*1024*1024;absolute=base['recorded_bytes']+headroom
    installed=old['installed'];installed['policies'][0]['limit']=absolute
    query=dict(installed,operation='inspect',sampled_ns=400)
    before=old['before']['post'];before['quota'].update(limit=headroom,remaining=headroom)
    after=copy.deepcopy(before);after['quota'].update(generation=2,limit=1,remaining=1)
    listener=dict(pid=1000,uid=0,netd_alive=True,deaths=0,death_ns=0,sampled_ns=150)
    fresh=dict(listener,pid=2000,sampled_ns=500)
    ready=dict(event='ready',uid=1001,gid=1001,pid=3000,cap_eff='0000000000000000',
               nonce=old['nonce'],local='10.254.0.2:1234',remote='10.254.0.1:5678')
    done=dict(ready,event='finished',attempted=1,successful=0,enobufs=1,start_ns=600,end_ns=700,release_ns=[650]);done.pop('cap_eff')
    automatic=copy.deepcopy(after);automatic['quota'].update(generation=3,limit=headroom-1228,remaining=headroom-1228)
    q=dict(query,sampled_ns=800,recorded_bytes=base['recorded_bytes']+1228)
    return dict(nonce=old['nonce'],headroom=headroom,absolute_limit=absolute,baseline=base,installed=installed,
        before=before,query=query,after=after,listener_before=listener,
        listener_after=dict(listener,netd_alive=False,deaths=1,death_ns=250,sampled_ns=450),
        fresh_listener_before=fresh,fresh_listener_after=dict(fresh,sampled_ns=1000),packet_ready=ready,packet=done,
        automatic=dict(query=q,check=dict(q,sampled_ns=900),quota=automatic),fixture=[],callbacks=dict(callbacks=[]),
        readiness='royd Ethernet quota readiness: received=yes conservative_used=yes\n')


class PolicyRestartAssessment(unittest.TestCase):
    def test_conservative_then_automatically_calculated_allowance(self):
        result=assess(case());self.assertEqual(result['initial_recovered_limit'],1)
        self.assertEqual(result['calculated_remaining'],8*1024*1024-1228)

    def test_original_full_limit_regrant_and_stale_policy_history_fail(self):
        changes=[
            lambda x:x['after']['quota'].update(limit=x['absolute_limit'],remaining=x['absolute_limit']),
            lambda x:x['query'].update(recorded_bytes=0),
            lambda x:x['query'].update(policies=[]),
            lambda x:x['query'].update(operation='poll'),
            lambda x:x['after']['quota'].update(present=False),
            lambda x:x['after']['quota'].update(contention=1),
            lambda x:x['after']['quota'].update(map_id=99),
            lambda x:x['after']['quota_admitted'].update(map_id=99),
            lambda x:x['after'].update(query=[[9,9],[9,9]]),
            lambda x:x['listener_after'].update(netd_alive=True,deaths=0),
        ]
        for change in changes:
            value=case();change(value)
            with self.subTest(change=change),self.assertRaises(ValueError):assess_initial(value)

    def test_a_one_byte_cap_alone_does_not_qualify_recovery(self):
        value=case();value['automatic']['quota']['quota'].update(limit=1,remaining=1)
        with self.assertRaises(ValueError):assess(value)

    def test_forced_poll_fake_callback_changed_source_and_new_privileges_fail(self):
        changes=[
            lambda x:x['automatic']['query'].update(operation='poll'),
            lambda x:x['automatic']['check'].update(recorded_bytes=0),
            lambda x:x['automatic']['quota']['quota'].update(limit=x['headroom'],remaining=x['headroom']),
            lambda x:x['automatic']['quota']['quota'].update(invalid=1),
            lambda x:x['fresh_listener_before'].update(pid=1000),
            lambda x:x['fresh_listener_after'].update(deaths=1),
            lambda x:x['packet_ready'].update(cap_eff='1'),
            lambda x:x['packet'].update(attempted=2),
            lambda x:x.update(readiness='royd Ethernet quota readiness: received=no conservative_used=yes\n'),
            lambda x:x['callbacks']['callbacks'].append(dict(sequence=1,nonce=x['nonce'],caller_uid=1000,
                caller_pid=0,name='eth0',interface='eth0',time_ns=750)),
        ]
        for change in changes:
            value=case();change(value)
            with self.subTest(change=change),self.assertRaises(ValueError):assess(value)

    def test_single_admission_is_authenticated_without_claiming_a_noiseless_startup_window(self):
        value=case();r=value['packet_ready'];value['packet'].update(successful=1,enobufs=0)
        receipt=dict(event='receive',uid=1001,step=1,count=1,sequence=0,kind=1,peer=r['local'],
            sha256=hashlib.sha256(packet(bytes.fromhex(value['nonce']),1,1001,0,1,1)).hexdigest())
        value['fixture']=[receipt];self.assertEqual(assess(value)['packet_receipts'],1)
        value['fixture'].append(receipt)
        with self.assertRaises(ValueError):assess(value)


class PostRuntimeHook(unittest.TestCase):
    def run_hook(self,directory,cid='owned'):
        hook=Path(__file__).resolve().parents[2]/'scripts/network-policy-restart-runtime.py'
        with patch.dict(os.environ,ROYD_POLICY_RESTART_HOOK=str(directory),ROYD_POLICY_RESTART_CID='owned'), \
             patch.object(sys,'argv',[str(hook),cid]):
            return runpy.run_path(str(hook),run_name='__main__')

    def test_continuation_executes_the_unchanged_real_runtime_runner(self):
        with tempfile.TemporaryDirectory() as tmp,patch('os.execv') as execute:
            directory=Path(tmp);(directory/'continue').write_text('owned\n');self.run_hook(directory)
            runner=str(Path(__file__).resolve().parents[2]/'scripts/assert-runtime.sh')
            execute.assert_called_once_with(runner,[runner,'owned'])
            self.assertTrue((directory/'ready.json').is_file());self.assertFalse((directory/'ready.tmp').exists())

    def test_wrong_owner_missing_release_and_changed_release_fail(self):
        with tempfile.TemporaryDirectory() as tmp,patch('os.execv') as execute:
            with self.assertRaises(ValueError):self.run_hook(Path(tmp),'foreign')
            execute.assert_not_called()
        with tempfile.TemporaryDirectory() as tmp,patch('os.execv') as execute,patch('time.monotonic',side_effect=[0,181]):
            with self.assertRaises(TimeoutError):self.run_hook(Path(tmp))
            execute.assert_not_called()
        with tempfile.TemporaryDirectory() as tmp,patch('os.execv') as execute:
            directory=Path(tmp);(directory/'continue').write_text('foreign\n')
            with self.assertRaises(ValueError):self.run_hook(directory)
            execute.assert_not_called()


if __name__=='__main__':unittest.main()
