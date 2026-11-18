#!/usr/bin/env python3
"""Exercise the production qualification lifecycle with isolated command fixtures."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[3]
CID = 'c' * 64
IMAGE = 'sha256:' + 'a' * 64
REPORT = b'\x1f\x8b\x00raw report\x00\xff'

DOCKER = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
p=Path(os.environ['FIXTURE_STATE']); s=json.loads(p.read_text()); a=sys.argv[1:]
with Path(os.environ['FIXTURE_COMMANDS']).open('a') as f: f.write(json.dumps(a)+'\n')
mode=os.environ.get('FIXTURE_MODE','pass')
def done(code=0, text=''):
 p.write_text(json.dumps(s))
 if text: print(text)
 sys.exit(code)
if a[:2]==['image','inspect']: done(text='sha256:'+'a'*64)
if a[0]=='inspect':
 if not s.get('container'): done(1)
 if '--format' not in a: done(text=json.dumps([dict(Id='c'*64, Image='sha256:'+'a'*64)]))
 fmt=a[a.index('--format')+1]
 if 'org.royd.test.owner' in fmt: done(text=s.get('owner','foreign')+' '+s.get('id','c'*64)+' '+s.get('image','sha256:'+'a'*64))
 done(text='status=running\nhealth=none')
if a[:2]==['volume','inspect']:
 if not s.get('volume'): done(1)
 done(text=s.get('volume_owner','foreign'))
if a[:2]==['volume','create']:
 s['volume']=True
 s['volume_owner']='foreign' if mode=='volume-race' else a[a.index('--label')+1].split('=',1)[1]
 done(text=a[-1])
if a[0]=='create':
 if mode=='create-fail': done(1)
 s['container']=True
 s['owner']=next(a[i+1].split('=',1)[1] for i,x in enumerate(a) if x=='--label' and a[i+1].startswith('org.royd.test.owner='))
 done(text='c'*64)
if a[0]=='start': done(1 if mode=='start-fail' else 0)
if a[0]=='port': done(text='127.0.0.1:45678')
if a[0]=='logs': done(1 if mode=='logs-fail' else 0, '[royd] logcat: forwarding Android logs to container output\nfull stdout and stderr fixture')
if a[0]=='exec':
 if 'getprop' in a: done(text='running')
 if 'dumpsys' in a: done()
 if mode in ['probe-fail','start-fail']: done(1, 'transport failed')
 if mode=='probe-timeout': done(124)
 if mode=='probe-invalid': done(text='unexpected')
 done(text='ROYD_REPORT_DIRECTORY='+('unavailable' if mode in ['unavailable','start-fail'] else 'present'))
if a[0]=='cp':
 if mode=='copy-fail': done(1)
 out=Path(a[-1]);out.mkdir();(out/'raw.bin').write_bytes(b'\x1f\x8b\x00raw report\x00\xff');done()
if a[0]=='rm':
 if mode=='remove-fail': done(1)
 s['container']=False;done()
if a[:2]==['volume','rm']: s['volume']=False;done()
done(2, 'unexpected docker command '+repr(a))
'''
STAGE = r'''#!/usr/bin/env python3
import json, os, signal, sys
from pathlib import Path
name=Path(sys.argv[0]).name
mode=os.environ.get('FIXTURE_MODE','pass')
with Path(os.environ['FIXTURE_STAGES']).open('a') as f:f.write(json.dumps([name,*sys.argv[1:]])+'\n')
if name=='security-evidence.sh':
 print('DOCKER_PRIVILEGED=true\nPID1_CAP_EFF=fixture\nPID1_CAP_BND=fixture\nPID1_NO_NEW_PRIVS=0\nPID1_SECCOMP=0')
if name=='binder-isolation-test.sh':
 p=Path(os.environ['ROYD_BINDER_OUTPUT_DIR']);p.mkdir();(p/'manifest.env').write_text('fixture\n')
 if mode in ['changed-owner','changed-volume','changed-image','changed-id']:
  p=Path(os.environ['FIXTURE_STATE']);s=json.loads(p.read_text())
  if mode=='changed-owner':s['owner']='foreign'
  elif mode=='changed-volume':s['volume_owner']='foreign'
  elif mode=='changed-image':s['image']='sha256:foreign'
  else:s['id']='foreign'
  p.write_text(json.dumps(s))
 if mode=='publish-race':Path(os.environ['ROYD_RUNTIME_RESULT_FILE']).write_text('foreign result\n')
 if mode=='canonical-race':Path(os.environ['ROYD_RUNTIME_EVIDENCE_DIR'],'result.env').write_text('foreign canonical\n')
 if mode=='publish-directory':Path(os.environ['ROYD_RUNTIME_RESULT_FILE']).mkdir()
 if mode=='publish-symlink':Path(os.environ['ROYD_RUNTIME_RESULT_FILE']).symlink_to(Path(os.environ['ROYD_RUNTIME_EVIDENCE_DIR']))
if name=='assert-runtime.sh' and mode=='signal':os.kill(os.getppid(),signal.SIGTERM)
if name=='host-check.sh' and mode=='host-fail':sys.exit(1)
if name=='image-inspect.sh' and mode=='image-fail':sys.exit(1)
if name=='assert-runtime.sh' and mode=='runtime-fail':sys.exit(1)
if name=='assert-android15-log-history.sh' and mode=='history-fail':sys.exit(1)
if name=='assert-app-responsiveness.sh' and mode=='anr-fail':sys.exit(1)
'''


def skeleton(root):
    """Copy the runner verbatim; replace external stages, never its lifecycle code."""
    (root / 'android').symlink_to(REPO / 'android', target_is_directory=True)
    runtime = root / 'runtime'
    runtime.mkdir()
    for p in (REPO / 'runtime').iterdir():
        if p.name != 'scripts':
            (runtime / p.name).symlink_to(p, target_is_directory=p.is_dir())
    scripts = runtime / 'scripts'
    scripts.mkdir()
    owned = {'qualification.sh', 'qualification-owned-lib.sh', 'runtime-result-lib.sh', 'container-evidence.sh'}
    stages = {'host-check.sh', 'image-inspect.sh', 'assert-security.sh', 'wait-for-boot.sh', 'wait-for-health.sh',
              'security-evidence.sh', 'assert-runtime.sh', 'adb-check.sh', 'binder-isolation-test.sh',
              'assert-android15-log-history.sh', 'assert-app-responsiveness.sh'}
    for p in (REPO / 'runtime/scripts').iterdir():
        dest = scripts / p.name
        if p.name in owned:
            shutil.copy2(p, dest)
        elif p.name in stages:
            dest.write_text(STAGE)
            dest.chmod(0o755)
        else:
            dest.symlink_to(p, target_is_directory=p.is_dir())
    return scripts


class QualificationTest(unittest.TestCase):
    def run_case(self, mode='pass', prepare=None):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name)
        scripts = skeleton(root)
        out = root / 'output'
        out.mkdir()
        bin_dir = root / 'bin'
        bin_dir.mkdir()
        (bin_dir / 'docker').write_text(DOCKER)
        (bin_dir / 'docker').chmod(0o755)
        (bin_dir / 'adb').write_text('#!/bin/sh\nexit 0\n')
        (bin_dir / 'adb').chmod(0o755)
        state = root / 'state.json'
        state.write_text('{}')
        env = dict(os.environ, PATH=str(bin_dir)+':'+os.environ['PATH'],
                   FIXTURE_STATE=str(state), FIXTURE_COMMANDS=str(root/'commands'), FIXTURE_STAGES=str(root/'stages'),
                   FIXTURE_MODE=mode, ROYD_ANDROID_VERSION='15', ROYD_QUALIFY_ARCH='x86_64',
                   ROYD_ANDROID_PROFILE='standard', ROYD_HAL_PROFILE='graphical', ROYD_SECURITY_MODE='privileged',
                   ROYD_GRAPHICS_BACKEND='software', ROYD_RESOURCE_PROFILE='low-memory', ROYD_IMAGE='fixture:mutable',
                   ROYD_PROFILE='default', ROYD_QUALIFY_CONTAINER='owned-fixture', ROYD_QUALIFY_REQUIRE_ADB='1',
                   ROYD_RUNTIME_RESULT_FILE=str(out/'result.env'), ROYD_RUNTIME_LOG_FILE=str(out/'run.log'),
                   ROYD_RUNTIME_EVIDENCE_DIR=str(out/'evidence'))
        if prepare:
            prepare(root, env)
        result = subprocess.run([str(scripts/'qualification.sh')], env=env, capture_output=True, text=True, timeout=30)
        commands = [json.loads(x) for x in (root/'commands').read_text().splitlines()] if (root/'commands').exists() else []
        stages = [json.loads(x) for x in (root/'stages').read_text().splitlines()] if (root/'stages').exists() else []
        return root, result, json.loads(state.read_text()), commands, stages

    def test_success_and_immutable_identity(self):
        root, p, state, commands, stages = self.run_case()
        self.assertEqual(p.returncode, 0, p.stdout+p.stderr)
        self.assertFalse(state['container']); self.assertFalse(state['volume'])
        result = (root/'output/result.env').read_text()
        for text in ['RESULT_FORMAT=5', 'RESULT_STATUS=pass', 'POST_HISTORY_STATUS=pass', 'MAIN_CLEANUP_STATUS=pass',
                     'DOCKER_PRIVILEGED=true', 'PID1_CAP_EFF=fixture', 'CONTAINER_ID='+CID]:
            self.assertIn(text, result)
        for kind in ['anr','dropbox']:
            self.assertEqual((root/'output/evidence'/kind/'raw.bin').read_bytes(), REPORT)
        create = next(c for c in commands if c[0]=='create')
        self.assertIn(IMAGE, create); self.assertNotIn('fixture:mutable', create)
        for c in commands:
            if c[0] in ['start','port','exec','rm']:
                self.assertIn(CID, c)
        self.assertEqual(next(s for s in stages if s[0]=='image-inspect.sh')[-1], IMAGE)
        self.assertEqual(next(s for s in stages if s[0]=='binder-isolation-test.sh')[-1], IMAGE)
        binder = next(i for i,s in enumerate(stages) if s[0]=='binder-isolation-test.sh')
        history = next(i for i,s in enumerate(stages) if s[0]=='assert-android15-log-history.sh')
        self.assertGreater(history, binder)
        final_logs = max(i for i,c in enumerate(commands) if c[0]=='logs')
        remove = next(i for i,c in enumerate(commands) if c[0]=='rm')
        self.assertLess(final_logs, remove)
        self.assertTrue((root/'output/evidence/stages/security_evidence.log').exists())

    def test_failed_capture_or_ownership_preserves_resources(self):
        for mode in ['logs-fail','probe-fail','probe-timeout','probe-invalid','copy-fail',
                     'changed-owner','changed-volume','changed-image','changed-id','remove-fail','start-fail']:
            with self.subTest(mode=mode):
                root,p,state,commands,_ = self.run_case(mode)
                self.assertNotEqual(p.returncode, 0, p.stdout+p.stderr)
                self.assertTrue(state['container']); self.assertTrue(state['volume'])
                self.assertIn('RESULT_STATUS=fail', (root/'output/result.env').read_text())
                self.assertFalse(any(c[:2]==['volume','rm'] for c in commands))
                if mode!='remove-fail':self.assertFalse(any(c[0]=='rm' for c in commands))

    def test_workload_and_late_failures_keep_reports_before_cleanup(self):
        for mode in ['runtime-fail','history-fail','anr-fail','signal']:
            with self.subTest(mode=mode):
                root,p,state,_,_ = self.run_case(mode)
                self.assertNotEqual(p.returncode, 0, p.stdout+p.stderr)
                self.assertFalse(state['container']); self.assertFalse(state['volume'])
                self.assertIn('RESULT_STATUS=fail', (root/'output/result.env').read_text())
                self.assertEqual((root/'output/evidence/dropbox/raw.bin').read_bytes(), REPORT)

    def test_unavailable_reports_and_never_started(self):
        for mode in ['unavailable']:
            with self.subTest(mode=mode):
                root,p,state,_,_=self.run_case(mode)
                self.assertEqual(p.returncode, 0 if mode=='unavailable' else 1, p.stdout+p.stderr)
                self.assertFalse(state['container']);self.assertFalse(state['volume'])
                self.assertIn('ANR_PROBE_STATUS=unavailable', (root/'output/evidence/anr-status.env').read_text())

    def test_creation_failures_do_not_adopt_resources(self):
        root,p,state,commands,_=self.run_case('volume-race')
        self.assertNotEqual(p.returncode,0)
        self.assertTrue(state['volume']);self.assertEqual(state['volume_owner'],'foreign')
        self.assertFalse(any(c[:2]==['volume','rm'] for c in commands))
        root,p,state,commands,_=self.run_case('create-fail')
        self.assertNotEqual(p.returncode,0)
        self.assertFalse(state['volume']);self.assertFalse(state.get('container',False))

    def test_prerequisites_do_not_launch_companions(self):
        for mode in ['host-fail','image-fail']:
            with self.subTest(mode=mode):
                _,p,_,commands,stages=self.run_case(mode)
                self.assertNotEqual(p.returncode,0)
                self.assertFalse(any(c[0]=='create' for c in commands))
                self.assertFalse(any(s[0]=='binder-isolation-test.sh' for s in stages))

    def test_preexisting_outputs_and_resources_are_untouched(self):
        for name in ['result.env','run.log','evidence','symlink','container','volume']:
            def prepare(root,env):
                if name in ['container','volume']:
                    (root/'state.json').write_text(json.dumps({name:True}))
                elif name=='evidence':
                    (root/'output/evidence').mkdir();(root/'output/evidence/retained').write_text('original')
                elif name=='symlink':
                    (root/'output/result.env').symlink_to(root/'missing')
                else:(root/'output'/name).write_text('original')
            with self.subTest(name=name):
                root,p,state,commands,_=self.run_case(prepare=prepare)
                self.assertEqual(p.returncode,2,p.stdout+p.stderr)
                self.assertFalse(any(c[0] in ['rm','create','start'] or c[:2]==['volume','rm'] for c in commands))
                if name in ['result.env','run.log']:self.assertEqual((root/'output'/name).read_text(),'original')
                if name=='evidence':self.assertEqual((root/'output/evidence/retained').read_text(),'original')
                if name in ['container','volume']:self.assertTrue(state[name])

    def test_atomic_publication_refuses_late_collision(self):
        root,p,state,_,_=self.run_case('publish-race')
        self.assertNotEqual(p.returncode,0)
        self.assertEqual((root/'output/result.env').read_text(),'foreign result\n')
        self.assertTrue((root/'output/evidence/result.env').is_file())
        self.assertFalse(state['container']);self.assertFalse(state['volume'])
        root,p,_,_,_=self.run_case('canonical-race')
        self.assertNotEqual(p.returncode,0,p.stdout+p.stderr)
        self.assertEqual((root/'output/evidence/result.env').read_text(),'foreign canonical\n')
        self.assertFalse((root/'output/result.env').exists())
        for mode in ['publish-directory', 'publish-symlink']:
            root,p,state,_,_=self.run_case(mode)
            self.assertNotEqual(p.returncode,0,p.stdout+p.stderr)
            dest=root/'output/result.env'
            self.assertTrue(dest.is_dir())
            self.assertEqual(list(dest.glob('*.tmp.*')),[])


if __name__=='__main__':
    unittest.main()
