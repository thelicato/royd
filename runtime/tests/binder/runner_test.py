"""Execute the real Binder runner against owned mock Docker resources."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
DOCKER = r'''#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
root=Path(os.environ['CASE_ROOT']); state=json.loads((root/'state.json').read_text())
args=sys.argv[1:]; mode=os.environ['CASE_MODE']
with (root/'commands.jsonl').open('a') as f:f.write(json.dumps(args)+'\n')
def save(): (root/'state.json').write_text(json.dumps(state))
def container(key):
 for name,item in state['containers'].items():
  if key in (name,item['id']):return name,item
 raise SystemExit(1)
if args[:2]==['image','inspect']:
 print('sha256:test');sys.exit(0)
if args[0]=='inspect':
 name,item=container(args[-1])
 if '--format' not in args:print(json.dumps([item]))
 elif 'org.royd.test.owner' in args[args.index('--format')+1]:print(item['owner'],item['id'],'sha256:test')
 else:print('name=/'+name+'\nid='+item['id']+'\nimage=sha256:test\nstatus=running\nrunning=true\nexit_code=0\noom_killed=false\nerror=\nhealth=healthy')
 sys.exit(0)
if args[0]=='volume':
 operation=args[1];name=args[-1]
 if operation=='create':
  owner=args[args.index('--label')+1].split('=',1)[1];state['volumes'][name]=owner;save();print(name)
 elif operation=='inspect':
  if name not in state['volumes']:sys.exit(1)
  print(state['volumes'][name])
 elif operation=='rm':del state['volumes'][name];save();print(name)
 else:sys.exit(91)
 sys.exit(0)
if args[0]=='create':
 name=args[args.index('--name')+1];side=name[-1]
 if mode=='create_failure' and side=='b':sys.exit(8)
 owner=next(a.split('=',1)[1] for a in args if a.startswith('org.royd.test.owner='))
 ident='id-'+side;state['containers'][name]=dict(id=ident,owner=owner);save();print(ident);sys.exit(0)
if args[0]=='start':
 name,item=container(args[-1])
 if mode=='start_failure' and name.endswith('-b'):sys.exit(7)
 print(item['id']);sys.exit(0)
if args[0]=='logs':
 name,item=container(args[-1]);assert '--timestamps' in args
 if mode=='capture_failure' and name.endswith('-a'):sys.exit(9)
 print('full boot log for '+name+'\n'+('SystemServer pre-watchdog fixture stack' if mode=='runtime_failure' else 'normal fixture event')+'\nlast retained line');sys.exit(0)
if args[0]=='rm':
 name,item=container(args[-1]);assert args[-1]==item['id']
 if mode=='cleanup_failure' and name.endswith('-a'):sys.exit(9)
 del state['containers'][name];save();sys.exit(0)
if args[0]=='exec':
 name,item=container(args[1])
 if args[2:]==['test','-d','/data/anr']:sys.exit(0 if mode in ['runtime_failure','anr_copy_failure'] else 1)
 assert args[2]=='/vendor/bin/royd-binder-info'
 base=100 if name.endswith('-a') or mode=='shared' else 200
 for n,path in enumerate(['/dev/royd-binderfs/binder-control','/dev/binder','/dev/hwbinder','/dev/vndbinder']):print(path+'='+str(base+n))
 sys.exit(0)
if args[0]=='cp':
 name,item=container(args[1].split(':',1)[0])
 if mode=='anr_copy_failure' and name.endswith('-a'):sys.exit(9)
 target=Path(args[2]);target.mkdir();(target/'anr_fixture').write_text('full watchdog thread dump');sys.exit(0)
raise SystemExit(92)
'''
STAGE = r'''#!/usr/bin/env python3
import json,os,signal,sys
from pathlib import Path
root=Path(os.environ['CASE_ROOT']); mode=os.environ['CASE_MODE']; stage=Path(sys.argv[0]).name
with (root/'stages.jsonl').open('a') as f:f.write(json.dumps([stage,*sys.argv[1:]])+'\n')
print(stage+' '+sys.argv[1],flush=True)
if mode=='owner_changed' and stage=='assert' and sys.argv[1].endswith('-a'):
 state=json.loads((root/'state.json').read_text());state['containers'][sys.argv[1]]['owner']='foreign';(root/'state.json').write_text(json.dumps(state));sys.exit(1)
if mode=='interrupted' and stage=='wait':os.kill(os.getppid(),signal.SIGTERM)
if mode=='runtime_failure' and stage=='assert' and sys.argv[1].endswith('-a'):
 print('error: Android 15 triggered a SystemServer pre-watchdog');sys.exit(1)
if mode=='boot_failure' and stage=='wait' and sys.argv[1].endswith('-b'):sys.exit(1)
'''


class Runner(unittest.TestCase):
    def test_qualification_reuse_preserves_previous_results(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            result = root/'result.env'
            log = root/'result.log'
            companion = root/'evidence/binder-isolation'
            companion.mkdir(parents=True)
            marker = companion/'preserve'
            for p in [result, log, marker]: p.write_text('preserve '+p.name)
            before = {p:p.read_bytes() for p in [result, log, marker]}
            env = dict(os.environ, ROYD_RUNTIME_RESULT_FILE=str(result),
                       ROYD_RUNTIME_LOG_FILE=str(log), ROYD_RUNTIME_EVIDENCE_DIR=str(companion.parent))
            run = subprocess.run([ROOT/'runtime/scripts/qualification.sh'], env=env,
                                 text=True, capture_output=True, timeout=10)
            self.assertEqual(run.returncode, 2, run.stdout+run.stderr)
            self.assertIn('Binder evidence already exists', run.stderr)
            self.assertEqual(before, {p:p.read_bytes() for p in before})

    def trial(self, mode):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        (root/'bin').mkdir()
        for name, source in [('docker', DOCKER), ('wait', STAGE), ('assert', STAGE)]:
            p = root/'bin'/name
            p.write_text(source)
            p.chmod(0o755)
        state = dict(containers={}, volumes={})
        if mode == 'existing_container':
            state['containers']['test-b'] = dict(id='foreign-id', owner='foreign')
        if mode == 'existing_volume':
            state['volumes']['test-b-data'] = 'foreign'
        original = json.loads(json.dumps(state))
        (root/'state.json').write_text(json.dumps(state))
        out = root/'evidence'
        if mode == 'existing_evidence':
            out.mkdir()
            (out/'preserve').write_text('untouched')
        env = dict(os.environ, CASE_ROOT=str(root), CASE_MODE=mode,
                   PATH=str(root/'bin')+':'+os.environ['PATH'], ROYD_BINDER_PREFIX='test',
                   ROYD_BINDER_OUTPUT_DIR=str(out), ROYD_BINDER_WAIT_RUNNER=str(root/'bin/wait'),
                   ROYD_BINDER_ASSERT_RUNNER=str(root/'bin/assert'))
        result = subprocess.run([ROOT/'runtime/scripts/binder-isolation-test.sh', 'mock:image'],
                                env=env, text=True, capture_output=True, timeout=15)
        commands = [json.loads(s) for s in (root/'commands.jsonl').read_text().splitlines()]
        state = json.loads((root/'state.json').read_text())
        manifest = dict(line.split('=', 1) for line in (out/'manifest.env').read_text().splitlines()) if (out/'manifest.env').exists() else None
        return root, result, commands, state, manifest, original

    def test_success_and_phase_failures(self):
        for mode in ['good', 'runtime_failure', 'boot_failure', 'shared', 'interrupted', 'create_failure', 'start_failure']:
            with self.subTest(mode=mode):
                root, result, commands, state, manifest, _ = self.trial(mode)
                self.assertEqual(result.returncode == 0, mode == 'good', result.stderr+result.stdout)
                self.assertEqual(manifest['RESULT_STATUS'], 'pass' if mode == 'good' else 'fail')
                self.assertEqual(state, dict(containers={}, volumes={}))
                self.assertEqual(manifest['CAPTURE_A_STATUS'], 'pass')
                for side in ['a'] if mode == 'create_failure' else ['a', 'b']:
                    evidence = root/'evidence'/side
                    self.assertIn('last retained line', (evidence/'container.log').read_text())
                    self.assertTrue((evidence/'container-inspect.json').is_file())
                    capture = commands.index(['logs', '--timestamps', 'id-'+side])
                    removal = commands.index(['rm', '-f', 'id-'+side])
                    self.assertLess(capture, removal)
                if mode == 'runtime_failure':
                    self.assertIn('pre-watchdog', (root/'evidence/runtime_a.log').read_text())
                    self.assertIn('pre-watchdog', (root/'evidence/a/container.log').read_text())
                    self.assertEqual((root/'evidence/a/anr/anr_fixture').read_text(), 'full watchdog thread dump')
                    self.assertEqual(manifest['RUNTIME_A_STATUS'], 'fail')
                    self.assertEqual(manifest['RUNTIME_B_STATUS'], 'not-run')
                if mode == 'good':
                    stages = [json.loads(s)[:2] for s in (root/'stages.jsonl').read_text().splitlines()]
                    self.assertEqual(stages, [['wait','test-a'], ['wait','test-b'], ['assert','test-a'], ['assert','test-b']])
                    self.assertEqual(manifest['IDENTITY_STATUS'], 'pass')
                else:
                    self.assertNotIn('Binder isolation test passed:', result.stdout)

    def test_existing_resources_and_evidence_are_untouched(self):
        for mode in ['existing_container', 'existing_volume', 'existing_evidence']:
            with self.subTest(mode=mode):
                root, result, commands, state, manifest, original = self.trial(mode)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(state, original)
                self.assertIsNone(manifest)
                self.assertFalse(any(c[0] in ['create','rm','start'] or c[:2] in [['volume','create'],['volume','rm']] for c in commands))
                if mode == 'existing_evidence': self.assertEqual((root/'evidence/preserve').read_text(), 'untouched')

    def test_capture_ownership_and_cleanup_failures(self):
        for mode in ['capture_failure', 'anr_copy_failure', 'owner_changed', 'cleanup_failure']:
            with self.subTest(mode=mode):
                _, result, commands, state, manifest, _ = self.trial(mode)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(manifest['RESULT_STATUS'], 'fail')
                self.assertEqual(manifest['CLEANUP_A_STATUS'], 'fail')
                self.assertIn('test-a', state['containers'])
                self.assertIn('test-a-data', state['volumes'])
                self.assertNotIn('test-b', state['containers'])
                self.assertNotIn('test-b-data', state['volumes'])
                if mode != 'cleanup_failure': self.assertNotIn(['rm','-f','id-a'], commands)
                if mode == 'owner_changed': self.assertNotIn(['logs','--timestamps','id-a'], commands)
                self.assertNotIn('Binder isolation test passed:', result.stdout)


if __name__ == '__main__':
    unittest.main()
