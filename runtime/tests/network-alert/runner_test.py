import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import sys
import run


class OwnershipTest(unittest.TestCase):
    def trial(self, directory):
        with patch.dict(run.os.environ, {'ROYD_ALERT_OUTPUT_DIR':str(Path(directory)/'new')}):
            return run.Trial()

    def test_unowned_container_is_not_removed(self):
        with tempfile.TemporaryDirectory() as directory:
            trial = self.trial(directory)
            trial.owned = True
            calls = []
            def fake(argv, name=None, **kwargs):
                calls.append([str(v) for v in argv])
                return 'unrelated another-owner\n'
            trial.run = fake
            trial.finish()
            self.assertFalse(any(v[:3]==['docker','rm','-f'] for v in calls))
            self.assertEqual(trial.manifest['RESULT_STATUS'],'fail')
            self.assertTrue(any('ownership mismatch' in error for error in trial.failures))

    def test_unowned_volume_is_not_removed(self):
        with tempfile.TemporaryDirectory() as directory:
            trial = self.trial(directory); trial.volume_owned = True
            calls = []
            def fake(argv, name=None, **kwargs):
                calls.append([str(v) for v in argv]); return 'another-owner\n'
            trial.run = fake
            trial.finish()
            self.assertFalse(any(v[:3]==['docker','volume','rm'] for v in calls))
            self.assertEqual(trial.manifest['RESULT_STATUS'],'fail')

    def test_incomplete_json_is_pending_but_invalid_complete_json_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            p = Path(directory)/'receipts'
            p.write_text('{"event":"ready"}\n{"event":')
            self.assertEqual(run.rows(p),[{'event':'ready'}])
            p.write_text('unexpected error\n')
            with self.assertRaises(json.JSONDecodeError): run.rows(p)

    def test_timeout_retains_partial_output_and_failure_journal(self):
        with tempfile.TemporaryDirectory() as directory:
            trial = self.trial(directory)
            with self.assertRaisesRegex(RuntimeError, 'command failed'):
                trial.run([sys.executable, '-c',
                           'import time; print("partial witness", flush=True); time.sleep(30)'],
                          'timeout.log', timeout=1)
            self.assertIn('partial witness', (trial.out/'timeout.log').read_text())
            journal = run.rows(trial.out/'commands.jsonl')
            self.assertEqual(journal[0]['status'], 124)
            self.assertGreater(journal[0]['end_ns'], journal[0]['start_ns'])

    def test_cleanup_failure_invalidates_otherwise_passing_result(self):
        with tempfile.TemporaryDirectory() as directory:
            trial = self.trial(directory)
            trial.owned = True
            for key in ['WORKLOAD_STATUS', 'RUNTIME_STATUS', 'RESTORE_STATUS',
                        'DETACH_STATUS', 'FIXTURE_STATUS']:
                trial.manifest[key] = 'pass'
            def fake(argv, name=None, **kwargs):
                if list(argv)[:3] == ['docker', 'rm', '-f']:
                    raise RuntimeError('owned container removal failed')
                return 'network-alert '+trial.container+'\n'
            trial.run = fake
            trial.finish()
            self.assertIn('RESULT_STATUS=fail\n', (trial.out/'manifest.env').read_text())
            failures = json.loads((trial.out/'failures.json').read_text())
            self.assertTrue(any('owned container removal failed' in v for v in failures))

    def test_existing_evidence_is_never_overwritten(self):
        with tempfile.TemporaryDirectory() as directory:
            trial = self.trial(directory)
            sentinel = trial.out/'retained'
            sentinel.write_text('original evidence')
            with self.assertRaises(FileExistsError): self.trial(directory)
            self.assertEqual(sentinel.read_text(), 'original evidence')


if __name__ == '__main__':
    unittest.main()
