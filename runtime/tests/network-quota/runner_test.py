import copy
import json
import io
import os
from pathlib import Path
import subprocess
import tempfile
import tarfile
import unittest
from unittest.mock import patch
from run import MAXIMUM, Trial
from assess_test import example


class Lifecycle(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.output = Path(self.temporary.name)/'trial'
        with patch.dict(os.environ, ROYD_QUOTA_OUTPUT_DIR=str(self.output)):
            self.trial = Trial()

    def tearDown(self):
        self.temporary.cleanup()

    def configure(self, capture_failure=False):
        t = self.trial
        t.cid, t.image, t.created, t.volume_owned = 'owned-id', 'pinned-image', True, True
        t.original, t.restore_needed = dict(limit=MAXIMUM), True
        self.calls = []
        t.owner = lambda: self.calls.append('owner')
        t.control = lambda label, *args: self.calls.append(('control', label, *args))
        t.direct = lambda *args: dict(quota=dict(present=True, limit=MAXIMUM))
        def run(argv, name=None, **kwargs):
            argv = list(map(str, argv))
            self.calls.append(argv)
            if argv[0].endswith('container-evidence.sh') and capture_failure:
                raise RuntimeError('capture failed')
            text = t.token if argv[:3] == ['docker', 'volume', 'inspect'] else ''
            code = 1 if argv[:2] == ['docker', 'exec'] else 0
            return subprocess.CompletedProcess(argv, code, text)
        t.run = run
        return t

    def test_restore_precedes_capture_and_owned_deletion(self):
        t = self.configure()
        t.finish()
        operations = [x for x in self.calls if isinstance(x, (tuple, list))]
        self.assertEqual(operations[0], ('control', 'restore-original', 'set', MAXIMUM))
        capture = next(i for i, x in enumerate(operations) if x[0].endswith('container-evidence.sh'))
        remove = operations.index(['docker', 'rm', '-f', 'owned-id'])
        self.assertLess(capture, remove)
        self.assertEqual(t.manifest['RESTORE_STATUS'], 'pass')
        self.assertEqual(t.manifest['CLEANUP_STATUS'], 'pass')

    def test_capture_failure_leaves_container_and_volume(self):
        t = self.configure(capture_failure=True)
        t.finish()
        self.assertFalse(any(isinstance(x, list) and x[:2] == ['docker', 'rm'] for x in self.calls))
        self.assertFalse(any(isinstance(x, list) and x[:3] == ['docker', 'volume', 'rm'] for x in self.calls))
        self.assertEqual(t.manifest['RESULT_STATUS'], 'fail')
        self.assertTrue(t.failures)

    def test_missing_ready_worker_archive_prevents_cleanup(self):
        t = self.configure()
        t.workers = dict(a=dict(directory='/owned/missing', ready=dict(uid=10096, pid=50)))
        t.command = lambda *args: None
        t.read_worker = lambda *args: dict(uid=10096, pid=50)
        t.finish()
        self.assertEqual(t.manifest['CAPTURE_STATUS'], 'fail')
        self.assertFalse(any(isinstance(x, list) and x[:2] == ['docker', 'rm'] for x in self.calls))
        self.assertTrue(any('ready worker evidence disappeared' in x for x in t.failures))

    def test_attempted_post_failure_is_not_reported_untested(self):
        t = self.configure()
        t.pre = True
        def rejected(name): raise RuntimeError('retained focus timeout')
        t.runtime = rejected
        t.finish()
        self.assertEqual(t.manifest['RUNTIME_STATUS'], 'fail')
        self.assertEqual(t.manifest['RESULT_STATUS'], 'fail')
        self.assertEqual(t.manifest['CAPTURE_STATUS'], 'pass')

    def test_quota_request_timeout_retains_restore_obligation(self):
        t = self.trial
        t.snapshot = lambda label: dict(post=dict(quota=dict(generation=5)))
        def committed_then_timeout(*args):
            self.assertTrue(t.restore_needed)
            raise TimeoutError('reply lost after commit')
        t.control = committed_then_timeout
        with self.assertRaises(TimeoutError):
            t.set_quota('new-limit', 100)
        self.assertTrue(t.restore_needed)

    def test_changed_identity_is_rejected(self):
        t = self.trial
        t.cid, t.image = 'owned-id', 'pinned-image'
        valid = dict(Id=t.cid, Image=t.image, Name='/'+t.container,
                     Config=dict(Labels={'org.royd.test': 'network-quota', 'org.royd.test.owner': t.token}),
                     Mounts=[dict(Destination='/data', Type='volume', Name=t.volume)])
        mutations = [
            lambda x: x.update(Id='other'),
            lambda x: x.update(Image='other'),
            lambda x: x['Config']['Labels'].update({'org.royd.test.owner': 'other'}),
            lambda x: x['Mounts'][0].update(Name='user-data'),
        ]
        for mutate in mutations:
            item = copy.deepcopy(valid)
            mutate(item)
            t.run = lambda *args, item=item: subprocess.CompletedProcess([], 0, json.dumps([item]))
            with self.subTest(mutation=mutate), self.assertRaises(ValueError):
                t.owner()

    def test_changed_namespace_prevents_observer_command(self):
        t = self.trial
        def changed(): raise ValueError('namespace changed')
        t.namespace_owner = changed
        t.run = lambda *args: self.fail('observer must not run after ownership failure')
        with self.assertRaises(ValueError):
            t.direct('snapshot.json', True)

    def test_existing_evidence_is_refused(self):
        witness = self.output/'retained'
        witness.write_text('original')
        with patch.dict(os.environ, ROYD_QUOTA_OUTPUT_DIR=str(self.output)), self.assertRaises(FileExistsError):
            Trial()
        self.assertEqual(witness.read_text(), 'original')

    def test_receive_release_follows_host_push(self):
        t = self.trial
        sample = example('receive', 1)
        worker = dict(ready=sample['ready'], step=0)
        t.workers = dict(a=worker)
        events = []
        t.snapshot = lambda label: sample['before'] if label.endswith('-before') else sample['after']
        t.command = lambda *args: dict(step=1, uid=10096)
        def read(worker, name):
            events.append(name.split('-')[0])
            return sample['app'] if name.startswith('result') else {}
        t.read_worker = read
        class Fixture:
            def push(self, *args): events.append('push')
            def records(self): return sample['fixture']
        t.fixture = Fixture()
        t.publish_file = lambda *args: events.append('release')
        t.worker_identity = lambda *args: None
        t.nonce = sample['ready']['nonce']
        with patch('run.time.sleep'):
            t.flow('incoming', 'a', 'receive', 1, 1, 0)
        self.assertEqual(events, ['started', 'push', 'release', 'result'])

    def test_between_window_budget_or_generation_change_is_rejected(self):
        t = self.trial
        sample = example()
        t.workers = dict(a=dict(ready=sample['ready']))
        t.snapshot = lambda label: sample['before']
        t.command = lambda *args: self.fail('must reject before requesting traffic')
        for key, value in [('remaining', 0), ('generation', 21), ('map_id', 99)]:
            t.expected_quota = dict(sample['before']['post']['quota'], **{key: value})
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, 'between packet windows'):
                t.flow('changed', 'a', 'send', 1, 0, 0)

    def test_service_refresh_requires_same_process_and_background_state(self):
        t = self.trial
        worker = dict(package='org.royd.networkprobe', launched=0, refresh=0,
                      ready=dict(uid=10096, pid=50))
        t.workers = dict(a=worker)
        t.fixture = type('Fixture', (), dict(address='172.17.0.1:1234'))()
        t.nonce = 'ab'*16
        t.dx = lambda *args, **kwargs: '10 (SERVICE)'
        t.read_worker = lambda *args: dict(nonce=t.nonce, uid=10096, pid=51, refresh=1)
        t.worker_identity = lambda *args: self.fail('replaced service must be rejected first')
        with self.assertRaisesRegex(ValueError, 'refresh receipt'):
            t.refresh_workers()

    def test_archive_preserves_binary_data(self):
        t = self.trial
        t.owner = lambda: None
        t.cid = 'owned-id'
        data = b'\xff\x00\n\r\x80'
        output = io.BytesIO()
        with tarfile.open(fileobj=output, mode='w') as archive:
            member = tarfile.TarInfo('./trace.bin')
            member.size = len(data)
            archive.addfile(member, io.BytesIO(data))
        raw = output.getvalue()
        def execute(argv, stdout, **kwargs):
            stdout.write(raw)
            return subprocess.CompletedProcess(argv, 0, stderr=b'')
        with patch('run.subprocess.run', execute):
            t.archive('/owned/directory', 'sample.tar')
        self.assertEqual((t.out/'sample.tar').read_bytes(), raw)

    def test_invalid_archive_is_rejected(self):
        t = self.trial
        t.owner = lambda: None
        t.cid = 'owned-id'
        def execute(argv, stdout, **kwargs):
            stdout.write(b'not an archive')
            return subprocess.CompletedProcess(argv, 0, stderr=b'')
        with patch('run.subprocess.run', execute), self.assertRaises(tarfile.ReadError):
            t.archive('/owned/directory', 'broken.tar')


if __name__ == '__main__': unittest.main()
