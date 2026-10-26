"""Owned disposable Docker qualification of netd's real global-alert Binder path."""
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import sys
import time
import traceback

ROOT = Path(__file__).resolve().parents[3]
SCRIPTS = ROOT/'runtime/scripts'
sys.path.insert(0, str(ROOT/'runtime/tests/network-accounting'))
from assess import assess as assess_udp, fixture_socket


def need(condition, message):
    if not condition:
        raise RuntimeError(message)


def rows(path):
    text = path.read_text() if path.exists() else ''
    return [json.loads(line) for line in text.splitlines(keepends=True) if line.endswith('\n')]


class Trial:
    def __init__(self):
        self.image = sys.argv[1] if len(sys.argv) == 2 else os.environ.get('ROYD_IMAGE', 'royd:dev')
        self.out = Path(os.environ.get('ROYD_ALERT_OUTPUT_DIR', ROOT/'.work'/('network-alert-'+time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())+'-'+str(os.getpid())))).resolve()
        self.out.mkdir(parents=False, exist_ok=False)
        self.container = 'royd-alert-'+str(os.getpid())+'-'+secrets.token_hex(3)
        self.volume = self.container+'-data'
        self.owned = self.volume_owned = self.pre = False
        self.probe = self.fixture = self.observer = None
        self.sequence = 0
        self.restore_needed = False
        self.original = None
        self.failures = []
        self.plan = []
        self.manifest = dict(ROYD_ALERT_EVIDENCE_FORMAT=1, RESULT_STATUS='fail', WORKLOAD_STATUS='not-tested',
                             RUNTIME_STATUS='not-tested', RESTORE_STATUS='not-tested', DETACH_STATUS='not-tested',
                             FIXTURE_STATUS='not-tested', IMAGE_ID='unknown')

    def save(self, name, data):
        with (self.out/name).open('x') as f:
            json.dump(data, f, indent=2)
            f.write('\n')

    def run(self, argv, name=None, *, data=None, timeout=30, check=True, env=None):
        argv = [str(x) for x in argv]
        before = time.monotonic_ns()
        try:
            result = subprocess.run(argv, input=data, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout, env=env)
        except subprocess.TimeoutExpired as error:
            partial = error.stdout or ''
            if isinstance(partial, bytes): partial = partial.decode('utf-8', errors='replace')
            result = subprocess.CompletedProcess(argv, 124, partial+'\nerror: host command timed out after '+str(timeout)+' seconds\n')
        with (self.out/'commands.jsonl').open('a') as log:
            log.write(json.dumps(dict(argv=argv, input=data, start_ns=before, end_ns=time.monotonic_ns(), status=result.returncode, output=name, text=result.stdout if name is None else None))+'\n')
        if name is not None:
            with (self.out/name).open('x') as log:
                log.write(result.stdout)
        if check:
            need(result.returncode == 0, 'command failed: '+repr(argv)+'\n'+result.stdout[-3000:])
        return result.stdout

    def dx(self, args, name=None, **kwargs):
        return self.run(['docker', 'exec', self.container, *args], name, **kwargs)

    def owner(self):
        need(self.run(['docker', 'inspect', '--format', '{{index .Config.Labels "org.royd.test"}} {{index .Config.Labels "org.royd.test.owner"}}', self.container]).strip() == 'network-alert '+self.container, 'container ownership mismatch')

    def runtime(self, name):
        env = dict(os.environ, ROYD_HAL_PROFILE='graphical', ROYD_GRAPHICS_BACKEND='software', ROYD_RESOURCE_PROFILE='low-memory')
        self.run([SCRIPTS/'assert-runtime.sh', self.container], name, timeout=180, env=env)

    def identity(self, name):
        text = self.run(['docker', 'inspect', '--format', '{{.Id}} {{.State.StartedAt}} {{.State.Running}} {{.RestartCount}} {{.State.OOMKilled}}', self.container])
        text += self.dx(['pidof', 'system_server']) + self.dx(['pidof', 'netd'])
        (self.out/name).write_text(text)
        return text

    def oci(self, name):
        return self.dx(['sh', '-c', 'ip -o -4 addr show dev eth0; ip -4 route show table main; ip link show dev eth0; cat /etc/resolv.conf; tc qdisc show dev eth0'], name)

    def wait(self, predicate, seconds, description):
        deadline = time.monotonic()+seconds
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(.05)
        raise RuntimeError('timed out: '+description)

    def direct(self, name):
        self.run(['nsenter', '--net=/proc/'+str(self.host_pid)+'/ns/net', self.out/'native/observe', 'inspect', self.bpf_root, self.namespace], name)
        return json.loads((self.out/name).read_text())

    def snapshot(self, name):
        temporary = self.out/'observer/request.tmp'
        with temporary.open('x') as f:
            f.write(name+'\n')
        os.link(temporary, self.out/'observer/request')
        temporary.unlink()
        self.wait(lambda: (self.out/('observer/'+name+'.json')).exists(), 5, 'observer '+name)
        return json.loads((self.out/('observer/'+name+'.json')).read_text())

    def state(self, name):
        text = self.dx(['timeout', '15', 'dumpsys', 'netd'], name)
        matches = re.findall(r'^royd global alert: generation=(\d+) bytes=(\d+) armed=(yes|no) committed=(\d+) error=(\d+) sample_ms=(\d+)$', text, re.M)
        need(len(matches) == 1, 'missing/ambiguous sampled backend state')
        g, b, a, c, e, interval = matches[0]
        value = dict(generation=int(g), bytes=int(b), armed=a == 'yes', committed=int(c), error=int(e), sample_ms=int(interval))
        need(value['generation'] > 0 and value['bytes'] > 0 and value['error'] == 0 and value['sample_ms'] == 250, 'unhealthy sampled backend')
        return value

    def java(self, mode, uid=0):
        env = ['ANDROID_DATA=/data', 'ANDROID_ROOT=/system', 'ANDROID_STORAGE=/storage',
               'ANDROID_ART_ROOT=/apex/com.android.art', 'ANDROID_I18N_ROOT=/apex/com.android.i18n',
               'ANDROID_TZDATA_ROOT=/apex/com.android.tzdata', 'BOOTCLASSPATH='+self.bootclasspath,
               'DEX2OATBOOTCLASSPATH='+self.dexclasspath, 'CLASSPATH='+self.android_dir+'/probe.dex']
        return ['docker', 'exec', '-i', '--user', str(uid)+':'+str(uid), self.container, 'env', *env,
                'app_process', '/system/bin', 'org.royd.alertprobe.GlobalAlertProbe', self.nonce, mode,
                str(self.netd_pid), str(self.original['bytes'])]

    def command(self, operation, value=0):
        need(self.probe is not None and self.probe.poll() is None, 'observer Java process exited')
        self.sequence += 1
        self.probe.stdin.write(f'{self.nonce} {self.sequence} {operation} {value}\n')
        self.probe.stdin.flush()
        sequence = self.sequence
        self.wait(lambda: any(r.get('event') == 'command' and r['sequence'] == sequence for r in rows(self.out/'probe.jsonl')), 10, 'Java command '+str(sequence))
        return next(r for r in rows(self.out/'probe.jsonl') if r.get('event') == 'command' and r['sequence'] == sequence)

    def quiet(self, label, expected, seconds=1.5):
        start = time.monotonic_ns()
        time.sleep(seconds)
        reply = self.command('status')
        need(reply['callbacks'] == expected, 'premature/duplicate alert: '+label)
        self.save(label+'-quiet.json', dict(start_ns=start, end_ns=time.monotonic_ns(), seconds=seconds, callbacks=expected, reply=reply, counters=self.snapshot(label+'-quiet')))

    def arm(self, label, threshold):
        before = self.state(label+'-before-state.log')
        counters_before = self.snapshot(label+'-before')
        reply = self.command('arm', threshold)
        counters_after = self.snapshot(label+'-after')
        after = self.state(label+'-after-state.log')
        need(after['generation'] == before['generation']+1 and after['bytes'] == threshold and after['armed'] and after['committed'] == before['committed'], 'registration update mismatch')
        item = dict(label=label, bytes=threshold, command=reply, state_before=before, state_after=after,
                    baseline_before=counters_before, baseline_after=counters_after)
        self.plan.append(item)
        return item

    def traffic(self, phase, count=256):
        before = self.snapshot('p'+str(phase)+'-before')
        name = 'worker-'+str(phase)+'.log'
        self.run(['docker', 'exec', '-i', '--user', '1000:1000', self.container, self.android_dir+'/traffic',
                  '-address', self.address, '-nonce', self.nonce, '-phase', phase, '-uid', 1000, '-count', count], name, data='start\n', timeout=25)
        after = self.snapshot('p'+str(phase)+'-after')
        result = assess_udp(before, after, [rows(self.out/name)], rows(self.out/'fixture.log'), phase, 'normal')
        self.save('phase-'+str(phase)+'.json', result)
        return after

    def crossed(self, label, expected, arm):
        self.wait(lambda: len([r for r in rows(self.out/'probe.jsonl') if r.get('event') == 'callback']) >= expected, 10, 'real Binder crossing')
        self.quiet(label, expected, 2)
        state = self.state(label+'-framework-state.log')
        need(state['generation'] == arm['state_after']['generation']+1 and state['bytes'] == self.original['bytes'] and state['armed'] and state['committed'] == arm['state_after']['committed']+1, 'framework did not poll/rearm from callback')
        self.save(label+'-framework.json', state)

    def body(self):
        for variable in ['DOCKER_HOST']:
            need(os.environ.get(variable, 'unix:///var/run/docker.sock').startswith('unix://'), 'local Docker required')
        need(self.run(['docker', 'context', 'inspect', '--format', '{{.Endpoints.docker.Host}}']).strip().startswith('unix://'), 'local Docker context required')
        self.image = self.run(['docker', 'image', 'inspect', '--format', '{{.Id}}', self.image]).strip()
        self.manifest['IMAGE_ID'] = self.image
        labels = self.run(['docker', 'image', 'inspect', '--format', '{{index .Config.Labels "org.royd.android-version"}} {{index .Config.Labels "org.royd.arch"}} {{index .Config.Labels "org.royd.image-profile"}} {{index .Config.Labels "org.royd.hal-profile"}} {{index .Config.Labels "org.royd.graphics-backend"}}', self.image]).strip()
        need(labels == '15 x86_64 standard graphical software', 'baseline image required')
        self.run([SCRIPTS/'network-alert-build.sh', self.out/'java'], 'java-build.log', timeout=120)
        self.run([SCRIPTS/'network-accounting-build.sh', self.out/'native'], 'native-build.log', timeout=120)
        tree = Path(os.environ.get('ROYD_ANDROID_TEST_TREE', ROOT/'.work/android-src-15'))
        env = dict(os.environ, ROYD_ANDROID_TEST_SYSTEM_MODULES=str(tree/'out/soong/.intermediates/libcore/core-all-system-modules/android_common/system'))
        self.run([SCRIPTS/'network-dns-build.sh', self.out/'apk'], 'apk-build.log', timeout=120, env=env)
        need(self.container not in self.run(['docker', 'ps', '-a', '--format', '{{.Names}}']).splitlines(), 'pre-existing container')
        need(self.volume not in self.run(['docker', 'volume', 'ls', '--format', '{{.Name}}']).splitlines(), 'pre-existing volume')
        self.run(['docker', 'volume', 'create', '--label', 'org.royd.test.owner='+self.container, self.volume], 'volume.log')
        need(self.run(['docker', 'volume', 'inspect', '--format', '{{index .Labels "org.royd.test.owner"}}', self.volume]).strip() == self.container, 'new volume ownership mismatch')
        self.volume_owned = True
        args = []
        for helper in ['security-args.sh', 'container-args.sh']:
            import shlex
            args += shlex.split(self.run([SCRIPTS/helper, *(['privileged'] if helper.startswith('security') else [])]))
        profile = self.run([SCRIPTS/'profile.sh', 'default'], env=dict(os.environ, ROYD_RESOURCE_PROFILE='low-memory')).split()
        self.run(['docker', 'create', *args, '--name', self.container, '--network', 'bridge', '--label', 'org.royd.test=network-alert', '--label', 'org.royd.test.owner='+self.container, '-v', self.volume+':/data', self.image, *profile], 'create.log')
        self.owned = True; self.owner()
        self.run(['docker', 'start', self.container], 'start.log')
        self.run([SCRIPTS/'wait-for-boot.sh', self.container, '180'], 'boot.log', timeout=210, env=dict(os.environ, ROYD_BOOT_WAIT_MARKER='ROYD: using delegated cgroup v2 subtree'))
        self.run([SCRIPTS/'wait-for-health.sh', self.container, '240'], 'health.log', timeout=250)
        self.run([SCRIPTS/'assert-security.sh', self.container, 'privileged'], 'security.log')
        self.android_dir = '/data/local/tmp/royd-alert-'+secrets.token_hex(8)
        self.dx(['mkdir', self.android_dir])
        for source, target in [(self.out/'java/dex/classes.dex', 'probe.dex'), (self.out/'native/traffic', 'traffic'), (self.out/'apk/probe.apk', 'probe.apk')]:
            self.run(['docker', 'cp', source, self.container+':'+self.android_dir+'/'+target])
        self.dx(['chmod', '755', self.android_dir, self.android_dir+'/traffic'])
        self.dx(['chmod', '644', self.android_dir+'/probe.dex', self.android_dir+'/probe.apk'])
        need('package:org.royd.networkprobe' not in self.dx(['pm', 'list', 'packages', 'org.royd.networkprobe']).splitlines(), 'pre-existing test package')
        need('Success' in self.dx(['timeout', '30', 'pm', 'install', '-t', self.android_dir+'/probe.apk'], 'install.log').splitlines(), 'test APK installation failed')
        uidtext = self.dx(['stat', '-c', '%u', '/data/user/0/org.royd.networkprobe'])
        self.uid = int(uidtext.strip()); need(10000 <= self.uid < 20000, 'ordinary test UID required')
        self.dx(['dumpsys', 'package', 'org.royd.networkprobe'], 'package.log')
        self.runtime('before-runtime.log'); self.pre = True
        self.manifest['WORKLOAD_STATUS'] = 'fail'
        self.initial_identity = self.identity('identity-before.txt')
        self.initial_oci = self.oci('oci-before.log')
        self.original = self.state('original-state.log'); need(self.original['armed'], 'initial window not armed')
        self.netd_pid = int(self.dx(['pidof', 'netd']).strip())
        self.host_pid = int(self.run(['docker', 'inspect', '--format', '{{.State.Pid}}', self.container]).strip())
        self.namespace = os.readlink('/proc/'+str(self.host_pid)+'/ns/net')
        need(self.namespace != os.readlink('/proc/self/ns/net') and self.namespace == self.dx(['readlink', '/proc/self/ns/net']).strip(), 'private netns required')
        self.bpf_root = '/proc/'+str(self.host_pid)+'/root/sys/fs/bpf/netd_shared'
        self.initial_links = self.direct('initial-links.json')
        self.bootclasspath = self.dx(['sed', '-n', 's/^export BOOTCLASSPATH //p', '/data/system/environ/classpath']).strip()
        self.dexclasspath = self.dx(['sed', '-n', 's/^export DEX2OATBOOTCLASSPATH //p', '/data/system/environ/classpath']).strip()
        need(self.bootclasspath and self.dexclasspath, 'generated Java paths required')
        gateway = self.run(['docker', 'inspect', '--format', '{{(index .NetworkSettings.Networks "bridge").Gateway}}', self.container]).strip()
        self.fixture = subprocess.Popen([str(self.out/'native/traffic'), '-mode', 'server', '-listen', gateway+':0'], stdout=(self.out/'fixture.log').open('x'), stderr=subprocess.STDOUT)
        self.wait(lambda: bool(rows(self.out/'fixture.log')), 5, 'nonce fixture')
        ready = rows(self.out/'fixture.log')[0]
        self.address, self.nonce = ready['address'], ready['nonce']
        (self.out/'observer').mkdir()
        self.observer = subprocess.Popen(['nsenter', '--net=/proc/'+str(self.host_pid)+'/ns/net', str(self.out/'native/observe'), 'observe', self.bpf_root, self.namespace, str(self.out/'native/observe.bpf.o'), str(self.out/'observer'), self.address.rsplit(':', 1)[1]], stdout=(self.out/'observer.log').open('x'), stderr=subprocess.STDOUT)
        self.wait(lambda: (self.out/'observer/ready.json').exists(), 5, 'pass-through observer')
        self.probe = subprocess.Popen(self.java('monitor'), stdin=subprocess.PIPE, stdout=(self.out/'probe.jsonl').open('x'), stderr=(self.out/'probe-stderr.log').open('x'), text=True)
        self.restore_needed = True
        self.wait(lambda: any(r.get('event') == 'ready' for r in rows(self.out/'probe.jsonl')), 15, 'real Binder listener')
        self.run(self.java('denied', self.uid), 'denied.jsonl', timeout=20)
        initial = self.state('before-invalid-state.log')
        self.command('invalid', 0); self.command('invalid', -1)
        need(self.state('after-invalid-state.log') == initial, 'rejected requests changed backend')
        first = self.arm('first', 628737)
        self.traffic(1); self.quiet('first-below', 0)
        self.traffic(2, 1); self.crossed('first-crossed', 1, first)
        self.arm('old', 628737)
        self.traffic(3); self.quiet('old-below', 1)
        self.arm('replacement', 1257472)
        self.traffic(4); self.quiet('replacement-below', 1)
        second = self.arm('second', 628737)
        self.traffic(5); self.quiet('second-below', 1)
        self.traffic(6, 1); self.crossed('second-crossed', 2, second)
        self.save('windows.json', self.plan)
        self.save('scope.json', dict(nonce=self.nonce, uid=self.uid, netd_pid=self.netd_pid, original=self.original))
        from assess_alert import assess
        self.save('assessment.json', assess(self.out))
        self.manifest['WORKLOAD_STATUS'] = 'pass'

    def attempt(self, label, operation):
        try:
            operation()
        except Exception:
            self.failures.append(label+': '+traceback.format_exc())

    def finish(self):
        if self.probe is not None:
            def stop():
                self.owner()
                if self.probe.poll() is None:
                    self.command('stop')
                    self.probe.stdin.close()
                need(self.probe.wait(timeout=15) == 0, 'probe exit failure')
                state = self.state('restored-state.log')
                need(state['bytes'] == self.original['bytes'] and state['armed'], 'normal threshold not restored')
                self.restore_needed = False
                self.manifest['RESTORE_STATUS'] = 'pass'
            self.attempt('observer restoration', stop)
        if self.restore_needed:
            def fallback_restore():
                self.owner()
                self.run(self.java('restore'), 'failure-restore.log', timeout=20)
                state = self.state('fallback-restored-state.log')
                need(state['bytes'] == self.original['bytes'] and state['armed'], 'fallback state not restored')
                self.restore_needed = False
                self.manifest['RESTORE_STATUS'] = 'pass'
            self.attempt('fallback restoration', fallback_restore)
        if self.observer is not None:
            def detach():
                (self.out/'observer/stop').touch()
                need(self.observer.wait(timeout=10) == 0, 'observer failed')
                final = self.direct('detached-links.json')
                need(all(final[k] == self.initial_links[k] for k in ('ifindex', 'map_id', 'production_links', 'query')), 'production attachments changed')
                self.manifest['DETACH_STATUS'] = 'pass'
            self.attempt('detach', detach)
        if self.fixture is not None:
            def stop_fixture():
                self.fixture.terminate()
                need(self.fixture.wait(timeout=10) == 143, 'fixture exit failure')
                self.save('fixture-assessment.json', fixture_socket(rows(self.out/'fixture.log')))
                self.manifest['FIXTURE_STATUS'] = 'pass'
            self.attempt('fixture stop', stop_fixture)
        if self.pre:
            def post():
                self.runtime('after-runtime.log')
                need(self.identity('identity-after.txt') == self.initial_identity, 'Android/Docker identity changed')
                need(self.oci('oci-after.log') == self.initial_oci, 'OCI networking/qdisc changed')
                self.manifest['RUNTIME_STATUS'] = 'pass'
            self.attempt('post runtime', post)
        if self.owned:
            self.attempt('full evidence', lambda: self.run([SCRIPTS/'container-evidence.sh', self.container, self.out/'container'], 'capture.log'))
        if self.owned:
            self.attempt('container cleanup', lambda: (self.owner(), self.run(['docker', 'rm', '-f', self.container], 'container-cleanup.log')))
        if self.volume_owned:
            def remove_volume():
                owner = self.run(['docker', 'volume', 'inspect', '--format', '{{index .Labels "org.royd.test.owner"}}', self.volume]).strip()
                need(owner == self.container, 'volume ownership mismatch')
                self.run(['docker', 'volume', 'rm', self.volume], 'volume-cleanup.log')
            self.attempt('volume cleanup', remove_volume)
        for child in [self.probe, self.fixture, self.observer]:
            if child is not None:
                def reap(child=child):
                    if child.poll() is None:
                        child.terminate()
                    child.wait(timeout=10)
                self.attempt('child cleanup', reap)
        self.save('failures.json', self.failures)
        if not self.failures and all(self.manifest[k] == 'pass' for k in ['WORKLOAD_STATUS','RUNTIME_STATUS','RESTORE_STATUS','DETACH_STATUS','FIXTURE_STATUS']):
            self.manifest['RESULT_STATUS'] = 'pass'
        with (self.out/'manifest.env').open('x') as f:
            for k, v in self.manifest.items(): f.write(str(k)+'='+str(v)+'\n')



def main():
    trial = Trial()
    try:
        trial.body()
    except Exception:
        trial.failures.append('workload: '+traceback.format_exc())
    finally:
        trial.finish()
    print('Global alert result:', trial.manifest['RESULT_STATUS'], 'evidence:', trial.out)
    if trial.failures: print('\n'.join(trial.failures), file=sys.stderr)
    return 0 if not trial.failures and trial.manifest['RESULT_STATUS'] == 'pass' else 1


if __name__ == '__main__':
    sys.exit(main())
