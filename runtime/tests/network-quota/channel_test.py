import json
import copy
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from channel import Channel
from run import Trial
import runner_test

NONCE = 'ab'*16
PEER = '''
import json,sys,time,os
mode=os.environ['QUOTA_TEST_PEER_MODE']
nonce='ab'*16
hello=dict(nonce=nonce,seq=0,status='ready',uid=0,pid=42,cap_eff='0')
if mode=='bad_hello': hello['nonce']='wrong'
print(json.dumps(hello),flush=True)
if mode=='dead':sys.exit(0)
if mode=='backpressure': time.sleep(2);sys.exit(0)
for line in sys.stdin:
 r=json.loads(line)
 if mode=='silent': time.sleep(2);break
 if mode=='oversize': print('x'*20000,flush=True);continue
 if mode=='truncated': sys.stdout.write('{');sys.stdout.flush();break
 value=dict(stopped=True) if r['op']=='stop' else dict(echo=r['op'])
 reply=dict(nonce=nonce,seq=r['seq'],status='pass',value=value)
 if mode=='bad_nonce': reply['nonce']='wrong'
 if mode=='bad_sequence': reply['seq']+=1
 if mode=='bad_status': reply['status']='fail'
 print(json.dumps(reply),flush=True)
 if r['op']=='stop':
  if mode=='bad_exit':sys.exit(17)
  break
'''


class Transport(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.directory = Path(self.temporary.name)
        self.process = None
        self.channel = None

    def tearDown(self):
        if self.channel and not self.channel.closed:
            try: self.channel.close()
            except (ValueError, BrokenPipeError): pass
        if self.process:
            if not self.process.stdin.closed: self.process.stdin.close()
            self.process.wait(timeout=5)
            self.process.stdout.close()
            self.process.stderr.close()
        self.temporary.cleanup()

    def start(self, mode):
        self.process = subprocess.Popen([sys.executable, '-u', '-c', PEER], stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0,
            env=dict(os.environ, QUOTA_TEST_PEER_MODE=mode))
        self.channel = Channel(self.process, NONCE, self.directory)
        return self.channel

    def test_complete_request_and_shutdown_with_raw_evidence(self):
        channel = self.start('normal')
        self.assertEqual(channel.request('hello'), dict(echo='hello'))
        channel.close()
        self.assertEqual(self.process.returncode, 0)
        self.assertIn(b'"stopped": true', (self.directory/'controller-stdout.bin').read_bytes())
        rows=[json.loads(x) for x in (self.directory/'controller-events.jsonl').read_text().splitlines()]
        self.assertEqual([x['value']['seq'] for x in rows if x['kind']=='request'], [1,2])

    def test_bad_greeting_is_rejected_and_retained(self):
        with self.assertRaisesRegex(ValueError, 'greeting'): self.start('bad_hello')
        self.assertIn(b'wrong', (self.directory/'controller-stdout.bin').read_bytes())

    def test_failed_exit_never_counts_as_clean_shutdown(self):
        channel=self.start('bad_exit')
        with self.assertRaisesRegex(ValueError,'exit failed'):channel.close()
        self.assertTrue(channel.closed and channel.broken)

    def test_already_exited_peer_marks_channel_failed(self):
        channel=self.start('dead')
        self.process.wait(timeout=5)
        with self.assertRaisesRegex(ValueError,'unavailable'):channel.request('control')
        self.assertTrue(channel.broken)

    def test_corrupt_reply_breaks_channel_without_replay(self):
        for mode in ('bad_nonce', 'bad_sequence', 'bad_status', 'oversize', 'truncated'):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as name:
                process=subprocess.Popen([sys.executable,'-u','-c',PEER],stdin=subprocess.PIPE,stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,bufsize=0,env=dict(os.environ,QUOTA_TEST_PEER_MODE=mode))
                channel=Channel(process,NONCE,Path(name))
                try:
                    with self.assertRaises((ValueError,EOFError)):channel.request('control')
                    self.assertTrue(channel.broken)
                    with self.assertRaisesRegex(ValueError,'unavailable'):channel.request('control')
                    self.assertTrue((Path(name)/'controller-stdout.bin').stat().st_size)
                finally:
                    with self.assertRaises(ValueError):channel.close()
                    process.wait(timeout=5);process.stdout.close();process.stderr.close()

    def test_read_timeout_and_write_backpressure_are_bounded(self):
        for mode in ('silent','backpressure'):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as name:
                process=subprocess.Popen([sys.executable,'-u','-c',PEER],stdin=subprocess.PIPE,stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,bufsize=0,env=dict(os.environ,QUOTA_TEST_PEER_MODE=mode))
                channel=Channel(process,NONCE,Path(name))
                try:
                    with self.assertRaises(TimeoutError):channel.request('control',value='x'*15000,timeout=.03)
                    self.assertTrue(channel.broken)
                finally:
                    with self.assertRaises(ValueError):channel.close()
                    process.wait(timeout=5);process.stdout.close();process.stderr.close()


class Ownership(unittest.TestCase):
    def test_stream_identity_preserves_process_state_capability_and_cgroup_checks(self):
        with tempfile.TemporaryDirectory() as name, patch.dict(os.environ,ROYD_QUOTA_OUTPUT_DIR=name+'/trial'):
            trial=Trial();trial.owner=lambda: None
            ready=dict(uid=10096,pid=500,cgroup='0::/royd/uid_10096/pid_500\n')
            worker=dict(ready=ready,start_ticks='99',package='org.royd.networkprobe')
            valid=dict(uid=10096,stat='500 (probe) '+' '.join(['S']+['0']*18+['99']),
                       status='CapEff:\t0000000000000000\n',cgroup=ready['cgroup'],pids=[500],uid_state=10)
            mutations=[lambda x:x.update(uid=0),lambda x:x.update(status='CapEff:\t1\n'),
                       lambda x:x.update(stat=x['stat'].rsplit(' ',1)[0]+' 98'),lambda x:x.update(cgroup='0::/royd/init\n'),
                       lambda x:x.update(pids=[500,501]),lambda x:x.update(uid_state=19)]
            for n,mutation in enumerate([None,*mutations]):
                observed=copy.deepcopy(valid)
                if mutation:mutation(observed)
                trial.channels[0]=type('Channel',(),dict(broken=False,closed=False,
                    request=lambda *a,observed=observed,**kw:observed))()
                if mutation:
                    with self.subTest(mutation=n),self.assertRaises(ValueError):trial.worker_identity(worker,'identity-'+str(n))
                else:trial.worker_identity(worker,'identity-'+str(n))

    def test_failed_channel_never_falls_back_during_workload(self):
        with tempfile.TemporaryDirectory() as name, patch.dict(os.environ,ROYD_QUOTA_OUTPUT_DIR=name+'/trial'):
            trial=Trial();trial.channels[0]=type('Channel',(),dict(broken=True,closed=False))()
            with self.assertRaisesRegex(ValueError,'failed during workload'):trial.available_channel()
            trial.finishing=True
            self.assertIsNone(trial.available_channel())

    def test_changed_container_prevents_controller_request(self):
        with tempfile.TemporaryDirectory() as name, patch.dict(os.environ,ROYD_QUOTA_OUTPUT_DIR=name+'/trial'):
            trial=Trial()
            def changed():raise ValueError('container changed')
            trial.owner=changed
            trial.channels[0]=type('Channel',(),dict(broken=False,closed=False,
                request=lambda *a,**kw:self.fail('must not issue request after identity failure')))()
            with self.assertRaisesRegex(ValueError,'container changed'):trial.control('invalid','set',0)


class ControllerCleanup(unittest.TestCase):
    setUp=runner_test.Lifecycle.setUp
    tearDown=runner_test.Lifecycle.tearDown
    configure=runner_test.Lifecycle.configure

    def test_broken_controller_prevents_resource_deletion(self):
        trial=self.configure()
        trial.manifest['CONTROLLER_STATUS']='fail'
        trial.channels[0]=type('Channel',(),dict(closed=True,broken=True))()
        trial.controller_processes=[type('Process',(),dict(poll=lambda _:0))()]
        trial.finish()
        self.assertEqual(trial.manifest['CAPTURE_STATUS'],'fail')
        self.assertEqual(trial.manifest['CONTROLLER_STATUS'],'fail')
        self.assertFalse(any(isinstance(x,list) and x[:2]==['docker','rm'] for x in self.calls))


if __name__=='__main__':unittest.main()
