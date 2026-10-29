"""Real ordinary/native UID quota packets in one freshly owned Docker namespace."""
import errno
import json
import os
from pathlib import Path
import re
import secrets
import shlex
import signal
import subprocess
import sys
import tarfile
import time
import traceback
from assess import assess_flow, need
from fixture import Fixture, IP_BYTES
from replay import replay
from channel import Channel
from peer import identify as identify_peer

ROOT = Path(__file__).resolve().parents[3]
SCRIPTS = ROOT/'runtime/scripts'
MAXIMUM = (1 << 63) - 1


class Trial:
    quota_inspect_mode = 'inspect-quota'
    quota_observe_mode = 'observe-quota'
    extra_required = ()

    def __init__(self):
        self.out = Path(os.environ.get('ROYD_QUOTA_OUTPUT_DIR', ROOT/'.work'/('network-quota-'+time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())+'-'+str(os.getpid())))).resolve()
        self.out.mkdir(parents=False, exist_ok=False)
        self.image = sys.argv[1] if len(sys.argv) == 2 else os.environ.get('ROYD_IMAGE', 'royd:dev')
        self.token = secrets.token_hex(16)
        self.container = 'royd-quota-'+str(os.getpid())+'-'+self.token[:6]
        self.volume = self.container+'-data'
        self.created = self.volume_owned = self.pre = self.restore_needed = False
        self.cid = None
        self.native = self.fixture = None
        self.observers, self.workers, self.failures = {}, {}, []
        self.snapshot_sequence = 0
        self.original = self.initial = None
        self.plan = []
        self.refresh_enabled = False
        self.expected_quota = None
        headers = os.environ.get('ROYD_QUOTA_PACKET_HEADERS', '0')
        need(headers in ('0', '1'), 'ROYD_QUOTA_PACKET_HEADERS must be 0 or 1')
        self.headers_enabled = headers == '1'
        self.header_process = None
        self.channels, self.controller_processes = {}, []
        self.finishing = False
        self.manifest = dict(ROYD_QUOTA_EVIDENCE_FORMAT=1, RESULT_STATUS='fail', WORKLOAD_STATUS='not-tested',
                             RESTORE_STATUS='not-tested', DETACH_STATUS='not-tested', FIXTURE_STATUS='not-tested',
                             RUNTIME_STATUS='not-tested', CAPTURE_STATUS='not-tested', CLEANUP_STATUS='not-tested',
                             IMAGE_ID='unknown', CONTAINER=self.container, VOLUME=self.volume)
        if self.headers_enabled:
            self.manifest.update(ROYD_QUOTA_EVIDENCE_FORMAT=2, PACKET_HEADERS_STATUS='not-tested')
        self.manifest.update(ROYD_QUOTA_EVIDENCE_FORMAT=3, CONTROLLER_STATUS='not-tested')

    def save(self, name, value):
        with (self.out/name).open('x') as f:
            json.dump(value, f, indent=2)
            f.write('\n')

    def run(self, argv, name=None, *, data=None, timeout=30, env=None, check=True):
        argv = [str(x) for x in argv]
        before = time.monotonic_ns()
        try:
            result = subprocess.run(argv, input=data, text=True, stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT, timeout=timeout, env=env)
        except subprocess.TimeoutExpired as error:
            text = error.stdout or ''
            if isinstance(text, bytes): text = text.decode('utf-8', errors='replace')
            result = subprocess.CompletedProcess(argv, 124, text+'\nerror: command timed out\n')
        with (self.out/'commands.jsonl').open('a') as f:
            f.write(json.dumps(dict(argv=argv, input=data, start_ns=before, end_ns=time.monotonic_ns(),
                                   status=result.returncode, output=name,
                                   text=result.stdout if name is None else None))+'\n')
        if name is not None:
            with (self.out/name).open('x') as f: f.write(result.stdout)
        if check:
            need(result.returncode == 0, 'command failed: '+repr(argv)+'\n'+result.stdout[-3000:])
        return result

    def owner(self):
        item = json.loads(self.run(['docker', 'inspect', self.cid or self.container]).stdout)[0]
        need(item['Id'] == self.cid and item['Name'] == '/'+self.container and item['Image'] == self.image,
             'container identity changed')
        need(item['Config']['Labels'].get('org.royd.test') == 'network-quota'
             and item['Config']['Labels'].get('org.royd.test.owner') == self.token, 'container ownership changed')
        mounts = [m for m in item['Mounts'] if m['Destination'] == '/data']
        need(len(mounts) == 1 and mounts[0]['Type'] == 'volume' and mounts[0]['Name'] == self.volume,
             'data ownership changed')
        return item

    def dx(self, args, name=None, *, uid=0, **kwargs):
        self.owner()
        return self.run(['docker', 'exec', '--user', str(uid)+':'+str(uid), self.cid, *args], name, **kwargs).stdout

    def wait(self, predicate, seconds, reason):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if predicate(): return
            time.sleep(.05)
        raise RuntimeError('timed out: '+reason)

    def namespace_owner(self):
        item = self.owner()
        need(item['State']['Running'] and item['State']['Pid'] == self.host_pid, 'container process changed')
        need(os.readlink('/proc/'+str(self.host_pid)+'/ns/net') == self.namespace
             and self.namespace != os.readlink('/proc/self/ns/net'), 'network namespace changed')

    def direct(self, name, quota=False):
        self.namespace_owner()
        self.run(['nsenter', '--net=/proc/'+str(self.host_pid)+'/ns/net', self.out/'native/observe',
                  self.quota_inspect_mode if quota else 'inspect', self.bpf_root, self.namespace], name)
        return json.loads((self.out/name).read_text())

    def snapshot(self, label):
        self.namespace_owner()
        self.snapshot_sequence += 1
        name = 's'+str(self.snapshot_sequence)+'-'+label
        result = {}
        for role, process in self.observers.items():
            need(process.poll() is None, role+' observer exited')
            directory = self.out/('observer-'+role)
            temporary = directory/'request.tmp'
            with temporary.open('x') as f: f.write(name+'\n')
            os.link(temporary, directory/'request')
            temporary.unlink()
            self.wait(lambda: (directory/(name+'.json')).exists() or process.poll() is not None, 5, role+' snapshot')
            need(process.poll() is None, role+' observer exited during snapshot')
            result[role] = json.loads((directory/(name+'.json')).read_text())
            need(result[role]['query'] == self.chains, 'observer chain changed')
        quota = result['post']['quota']
        for key in ('map_id', 'drops_map_id'):
            need(quota[key] == self.original[key], 'quota map replaced')
        need(quota['invalid'] == quota['contention'] == 0, 'quota backend fault')
        return result

    def java(self, cls, classpath, args, uid=0):
        environment = ['ANDROID_DATA=/data', 'ANDROID_ROOT=/system', 'ANDROID_STORAGE=/storage',
                       'ANDROID_ART_ROOT=/apex/com.android.art', 'ANDROID_I18N_ROOT=/apex/com.android.i18n',
                       'ANDROID_TZDATA_ROOT=/apex/com.android.tzdata', 'BOOTCLASSPATH='+self.bootclasspath,
                       'DEX2OATBOOTCLASSPATH='+self.dexclasspath, 'CLASSPATH='+self.android_dir+'/'+classpath]
        return ['docker', 'exec', '--user', str(uid)+':'+str(uid), self.cid, 'env', *environment,
                'app_process', '/system/bin', cls, *map(str, args)]

    def control(self, label, operation, value=0, expected=0, uid=0):
        if self.refresh_enabled: self.refresh_workers()
        self.owner()
        channel = self.available_channel(uid)
        if channel is not None:
            value_out = channel.request('control', operation=operation, bytes=value, expected=expected, timeout=20)
            with (self.out/(label+'.log')).open('x') as output: output.write(json.dumps(value_out)+'\n')
            rows = [value_out]
        else:
            command = self.java('org.royd.alertprobe.QuotaControlProbe', 'control.dex',
                                [self.nonce, operation, value, expected], uid)
            self.run(command, label+'.log', timeout=20)
            rows = [json.loads(line) for line in (self.out/(label+'.log')).read_text().splitlines() if line.startswith('{')]
        need(len(rows) == 1, 'missing/ambiguous Binder receipt')
        receipt = rows[0]
        need(receipt['pid'] > 1 and (uid == 0 or int(receipt['cap_eff'], 16) == 0), 'Binder caller process/capabilities')
        need(receipt == dict(receipt, nonce=self.nonce, uid=uid, operation=operation, bytes=value,
                             error=0 if expected == -1 else expected, denied=expected == -1), 'Binder receipt identity')
        return receipt

    def read_worker(self, worker, name):
        directory = worker['directory']
        channel = self.available_channel()
        if channel is not None and 'ready' in worker:
            self.owner()
            return channel.request('read', directory=directory, uid=worker['ready']['uid'], name=name)
        def ready():
            text = self.dx(['timeout', '5', 'sh', '-c',
                            'if test -s "$1/error.json"; then printf error; elif test -s "$1/$2.json"; then printf ready; else printf pending; fi',
                            'sh', directory, name]).strip()
            need(text != 'error', 'worker error: '+self.dx(['cat', directory+'/error.json']) if text == 'error' else 'worker error')
            return text == 'ready'
        self.wait(ready, 20, 'worker '+name)
        return json.loads(self.dx(['timeout', '5', 'cat', directory+'/'+name+'.json']))

    def command(self, worker, operation, count):
        worker['step'] += 1
        request = dict(nonce=self.nonce, uid=worker['ready']['uid'], step=worker['step'], op=operation, count=count)
        self.publish_file(worker, 'command-'+str(worker['step']), json.dumps(request, separators=(',', ':')))
        return request

    def publish_file(self, worker, name, value):
        channel = self.available_channel()
        if channel is not None:
            self.owner()
            need(channel.request('publish', directory=worker['directory'], uid=worker['ready']['uid'], name=name, value=value)
                 == dict(published=name), 'publication receipt')
            return
        target = worker['directory']+'/'+name
        self.dx(['timeout', '5', 'sh', '-c', 'set -eC; printf "%s\\n" "$1" > "$2.tmp"; ln "$2.tmp" "$2"; rm "$2.tmp"',
                 'sh', value, target], uid=worker['ready']['uid'])

    def assess_item(self, item):
        return assess_flow(item)

    def flow(self, label, role, op, count, passed, remaining):
        if self.refresh_enabled: self.refresh_workers()
        window = dict(start_monotonic_ns=time.monotonic_ns(), start_realtime_ns=time.time_ns())
        worker = self.workers[role]
        before = self.snapshot(label+'-before')
        if self.expected_quota is not None:
            need(before['post']['quota'] == self.expected_quota, 'quota changed between packet windows')
        if remaining is None:
            quota = before['post']['quota']
            need(self.expected_quota is None and quota['present'] and quota['limit'] == MAXIMUM,
                 'dynamic remainder is only allowed for unlimited baseline')
            remaining = quota['remaining'] - count * IP_BYTES
        request = self.command(worker, op, count)
        step, uid = request['step'], request['uid']
        self.read_worker(worker, 'started-'+str(step))
        if op == 'receive':
            self.fixture.push(uid, step, count)
            self.publish_file(worker, 'release-'+str(step), self.nonce)
        app = self.read_worker(worker, 'result-'+str(step))
        # Wait for the expected receipt count only. Never retransmit a packet.
        if op == 'send' and passed:
            self.wait(lambda: len([r for r in self.fixture.records() if r['uid'] == uid and r['step'] == step]) >= passed,
                      3, 'fixture receipts')
        time.sleep(.15)
        after = self.snapshot(label+'-after')
        window.update(end_monotonic_ns=time.monotonic_ns(), end_realtime_ns=time.time_ns())
        item = dict(label=label, uid=uid, step=step, op=op, count=count, passed=passed, remaining=remaining,
                    ready=worker['ready'], app=app, before=before, after=after, fixture=self.fixture.records())
        if self.headers_enabled: item['diagnostic_window'] = window
        self.save(label+'.json', item)
        result = self.assess_item(item)
        if self.expected_quota is not None: self.expected_quota = after['post']['quota']
        self.worker_identity(worker, label)
        self.save(label+'-assessment.json', result)
        self.plan.append(dict(label=label, role=role, **result))
        return after['post']['quota']

    def refresh_workers(self):
        # Stock Android stops idle ordinary services. Use their real visible launchers,
        # never an exemption, timeout change or replacement worker/socket.
        due = [w for w in self.workers.values() if 'package' in w
               and time.monotonic() - w['launched'] >= 15]
        if not due: return
        self.dx(['input', 'keyevent', 'KEYCODE_WAKEUP'])
        self.dx(['wm', 'dismiss-keyguard'])
        for worker in due:
            worker['refresh'] += 1
            n = worker['refresh']
            worker['launched'] = time.monotonic()
            label = 'refresh-'+str(worker['ready']['uid'])+'-'+str(n)
            self.dx(['timeout', '30', 'am', 'start', '-W', '-n', worker['package']+'/org.royd.networkprobe.QuotaProbeLauncher',
                     '--es', 'address', self.fixture.address, '--es', 'nonce', self.nonce,
                     '--ei', 'refresh', str(n)], label+'.log')
            receipt = self.read_worker(worker, 'refresh-'+str(n))
            need(receipt == dict(nonce=self.nonce, uid=worker['ready']['uid'],
                                 pid=worker['ready']['pid'], refresh=n), 'service refresh receipt')
            self.wait(lambda: self.dx(['timeout', '10', 'am', 'get-uid-state', str(receipt['uid'])]).strip()
                      == '10 (SERVICE)', 10, 'service state after visible refresh')
            self.worker_identity(worker, label)
            self.save(label+'.json', receipt)

    def worker_identity(self, worker, label):
        value = worker['ready'];pid, uid = value['pid'], value['uid']
        channel = self.available_channel()
        if channel is not None:
            self.owner()
            observed = channel.request('identity', pid=pid, uid=uid, package=worker.get('package', ''))
            self.save(label+'-identity.json', observed)
            need(observed['uid'] == uid, 'worker UID changed')
            need(observed['stat'].rsplit(')', 1)[1].split()[19] == worker['start_ticks'], 'worker PID reused')
            need(re.search(r'^CapEff:\s+0+$', observed['status'], re.M) is not None, 'worker gained capabilities')
            need(observed['cgroup'] == value['cgroup'], 'worker cgroup changed')
            if uid >= 10000:
                need(observed['pids'] == [pid], 'app process changed')
                need(observed['uid_state'] == 10, 'app UID state changed')
            return
        need(self.dx(['stat', '-c', '%u', '/proc/'+str(pid)]).strip() == str(uid), 'worker UID changed')
        current = self.dx(['cat', '/proc/'+str(pid)+'/stat'])
        need(current.rsplit(')', 1)[1].split()[19] == worker['start_ticks'], 'worker PID reused')
        status = self.dx(['cat', '/proc/'+str(pid)+'/status'], label+'-status.log')
        need(re.search(r'^CapEff:\s+0+$', status, re.M) is not None, 'worker gained capabilities')
        need(self.dx(['cat', '/proc/'+str(pid)+'/cgroup'], label+'-cgroup.log') == value['cgroup'], 'worker cgroup changed')
        if uid >= 10000:
            need(self.dx(['pidof', worker['package']]).strip() == str(pid), 'app process changed')
            need(self.dx(['timeout', '10', 'am', 'get-uid-state', str(uid)]).strip() == '10 (SERVICE)', 'app UID state changed')

    def identity(self, name):
        item = self.owner()
        value = dict(id=item['Id'], started=item['State']['StartedAt'], restart_count=item['RestartCount'],
                     oom=item['State']['OOMKilled'], running=item['State']['Running'],
                     system_server=self.dx(['pidof', 'system_server']).strip(), netd=self.dx(['pidof', 'netd']).strip())
        self.save(name, value)
        return value

    def oci(self, name):
        return self.dx(['sh', '-c', 'ip -o -4 addr show dev eth0; ip -4 route show table main; ip link show dev eth0; cat /etc/resolv.conf; tc qdisc show dev eth0'], name)

    def runtime(self, name):
        self.owner()
        self.run([SCRIPTS/'assert-runtime.sh', self.cid], name, timeout=180,
                 env=dict(os.environ, ROYD_HAL_PROFILE='graphical', ROYD_GRAPHICS_BACKEND='software', ROYD_RESOURCE_PROFILE='low-memory'))

    def available_channel(self, uid=0):
        channel = self.channels.get(uid)
        if channel is None: return None  # Initial registration has no controller yet.
        if channel.broken or channel.closed:
            need(self.finishing, 'controller failed during workload')
            return None  # Bounded original commands remain available for failure restoration.
        return channel

    def before_close_controllers(self):
        pass

    def replay_packets(self):
        return replay(self.out)

    def start_controller(self, uid, tag):
        self.namespace_owner()
        self.manifest['CONTROLLER_STATUS'] = 'fail'
        command = self.java('org.royd.alertprobe.QuotaControlProbe', 'control.dex',
                            [self.nonce, 'serve' if uid == 0 else 'serve-control'], uid)
        command.insert(2, '-i')
        self.save(tag+'-command.json', command)
        process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=(self.out/(tag+'-stderr.log')).open('xb'), bufsize=0)
        self.controller_processes.append(process)
        channel = Channel(process, self.nonce, self.out, prefix=tag, uid=uid)
        self.channels[uid] = channel
        self.save(tag+'-hello.json', channel.hello)
        pid = channel.hello['pid']
        need(self.dx(['stat', '-c', '%u', '/proc/'+str(pid)]).strip() == str(uid), 'controller process UID')
        self.dx(['cat', '/proc/'+str(pid)+'/stat'], tag+'-proc-stat.log')
        return channel

    def capture_peer(self, label):
        self.namespace_owner()
        inside = json.loads(self.run(['nsenter', '--net=/proc/'+str(self.host_pid)+'/ns/net',
                                     'ip', '-j', '-d', 'link', 'show', 'dev', 'eth0']).stdout)
        outside = json.loads(self.run(['ip', '-j', '-d', 'link', 'show']).stdout)
        identity = identify_peer(inside, outside, self.initial['ifindex'])
        name = identity['host']['ifname']
        addresses = json.loads(self.run(['ip', '-j', 'addr', 'show', 'dev', name]).stdout)
        settings = {}
        for key in ('disable_ipv6', 'accept_ra', 'forwarding', 'router_solicitations',
                    'router_solicitation_interval', 'router_solicitation_max_interval'):
            try: settings[key] = (Path('/proc/sys/net/ipv6/conf')/name/key).read_text().strip()
            except FileNotFoundError: settings[key] = None  # IPv6 can be unavailable on an IPv4 host.
        self.namespace_owner()
        self.save(label+'.json', dict(identity=identity, addresses=addresses, ipv6_settings=settings))
        return identity

    def start_headers(self):
        self.namespace_owner()
        self.header_peer = self.capture_peer('packet-peer-before')
        self.header_directory = self.out/'packet-headers'
        self.header_directory.mkdir()
        self.manifest['PACKET_HEADERS_STATUS'] = 'fail'
        self.header_process = subprocess.Popen(['nsenter', '--net=/proc/'+str(self.host_pid)+'/ns/net',
                sys.executable, str(ROOT/'runtime/tests/network-quota/packet_headers.py'), str(self.header_directory),
                self.namespace, str(self.initial['ifindex']), str(os.getpid())],
                stdout=(self.out/'packet-headers.log').open('x'), stderr=subprocess.STDOUT)
        self.wait(lambda: (self.header_directory/'ready.json').exists() or self.header_process.poll() is not None,
                  5, 'packet header observer')
        need(self.header_process.poll() is None, 'packet header observer failed to start')
        value = json.loads((self.header_directory/'ready.json').read_text())
        need(value['namespace'] == self.namespace and value['ifindex'] == self.initial['ifindex']
             and value['pid'] == self.header_process.pid
             and os.readlink('/proc/'+str(value['pid'])+'/ns/net') == self.namespace, 'packet observer identity')

    def stop_headers(self):
        self.namespace_owner()
        (self.header_directory/'stop').touch(exist_ok=False)
        need(self.header_process.wait(timeout=10) == 0, 'packet header observer failed')
        value = json.loads((self.header_directory/'result.json').read_text())
        need(value['status'] == 'pass' and not value['errors'] and value['drops'] == 0
             and value['frames'] == value['packets']
             and value['namespace'] == self.namespace and value['ifindex'] == self.initial['ifindex'],
             'packet header observer incomplete')
        rows = (self.header_directory/'headers.jsonl').read_text().splitlines()
        need(len(rows) == value['frames'] and [json.loads(r)['sequence'] for r in rows] == list(range(1, len(rows)+1)),
             'incomplete packet header ledger')
        need(self.capture_peer('packet-peer-after') == self.header_peer, 'packet peer identity changed')
        self.manifest['PACKET_HEADERS_STATUS'] = 'pass'

    def body(self):
        need(os.environ.get('DOCKER_HOST', 'unix:///var/run/docker.sock').startswith('unix://'), 'local Docker required')
        need(self.run(['docker', 'context', 'inspect', '--format', '{{.Endpoints.docker.Host}}']).stdout.strip().startswith('unix://'), 'local Docker context required')
        image = json.loads(self.run(['docker', 'image', 'inspect', self.image]).stdout)[0]
        self.image = image['Id'];self.manifest['IMAGE_ID'] = self.image
        need([image['Config']['Labels'].get('org.royd.'+k) for k in ('android-version', 'arch', 'image-profile', 'hal-profile', 'graphics-backend')]
             == ['15', 'x86_64', 'standard', 'graphical', 'software'], 'Android 15 baseline required')
        self.run([SCRIPTS/'network-netd-probe-build.sh', self.out/'java', ROOT/'runtime/tests/network-alert/QuotaControlProbe.java'], 'java-build.log', timeout=120)
        self.run([SCRIPTS/'network-accounting-build.sh', self.out/'native'], 'native-build.log', timeout=120)
        tree = Path(os.environ.get('ROYD_ANDROID_TEST_TREE', ROOT/'.work/android-src-15'))
        env = dict(os.environ, ROYD_NETWORK_DNS_POLICY='1', ROYD_ANDROID_TEST_SYSTEM_MODULES=str(tree/'out/soong/.intermediates/libcore/core-all-system-modules/android_common/system'))
        self.run([SCRIPTS/'network-dns-build.sh', self.out/'apk'], 'apk-build.log', timeout=120, env=env)
        need(self.run(['docker', 'inspect', self.container], check=False).returncode != 0, 'existing container')
        need(self.run(['docker', 'volume', 'inspect', self.volume], check=False).returncode != 0, 'existing volume')
        self.run(['docker', 'volume', 'create', '--label', 'org.royd.test.owner='+self.token, self.volume], 'volume-create.log')
        self.volume_owned = True
        need(self.run(['docker', 'volume', 'inspect', '--format', '{{index .Labels "org.royd.test.owner"}}', self.volume]).stdout.strip() == self.token, 'new volume ownership mismatch')
        args = []
        for helper, options in [('security-args.sh', ['privileged']), ('container-args.sh', [])]:
            args += shlex.split(self.run([SCRIPTS/helper, *options]).stdout)
        profile = shlex.split(self.run([SCRIPTS/'profile.sh', 'default'], env=dict(os.environ, ROYD_RESOURCE_PROFILE='low-memory')).stdout)
        self.cid = self.run(['docker', 'create', *args, '--name', self.container, '--network', 'bridge',
                             '--label', 'org.royd.test=network-quota', '--label', 'org.royd.test.owner='+self.token,
                             '-v', self.volume+':/data', self.image, *profile], 'create.log').stdout.strip()
        self.created = True;self.owner()
        self.run(['docker', 'start', self.cid], 'start.log')
        self.run([SCRIPTS/'wait-for-boot.sh', self.cid, '180'], 'boot.log', timeout=210,
                 env=dict(os.environ, ROYD_BOOT_WAIT_MARKER='ROYD: using delegated cgroup v2 subtree'))
        self.run([SCRIPTS/'wait-for-health.sh', self.cid, '240'], 'health.log', timeout=250)
        self.run([SCRIPTS/'assert-security.sh', self.cid, 'privileged'], 'security.log')
        self.runtime('before-runtime.log');self.pre = True
        self.initial_identity = self.identity('identity-before.json')
        self.initial_oci = self.oci('oci-before.log')
        self.host_pid = self.owner()['State']['Pid']
        self.namespace = os.readlink('/proc/'+str(self.host_pid)+'/ns/net')
        self.bpf_root = '/proc/'+str(self.host_pid)+'/root/sys/fs/bpf/netd_shared'
        self.namespace_owner()
        self.initial = self.direct('initial-accounting.json')
        self.initial_quota = self.direct('initial-quota.json', True)
        self.original = self.initial_quota['quota']
        need(self.original['present'] and self.original['limit'] == MAXIMUM
             and self.original['invalid'] == self.original['contention'] == 0, 'healthy original unlimited quota required')
        for d in (0, 1):
            need(self.initial['query'][d] == [self.initial['production_links'][d], self.initial_quota['production_links'][d]],
                 'unexpected initial TCX chain')
        self.bootclasspath = self.dx(['sed', '-n', 's/^export BOOTCLASSPATH //p', '/data/system/environ/classpath']).strip()
        self.dexclasspath = self.dx(['sed', '-n', 's/^export DEX2OATBOOTCLASSPATH //p', '/data/system/environ/classpath']).strip()
        need(self.bootclasspath and self.dexclasspath and '\n' not in self.bootclasspath+self.dexclasspath, 'generated classpaths required')
        self.android_dir = '/data/local/tmp/royd-quota-'+self.token
        self.dx(['mkdir', self.android_dir])
        self.dx(['chmod', '755', self.android_dir])
        for source, target in [(self.out/'java/dex/classes.dex', 'control.dex'), (self.out/'apk/probe.apk', 'probe.apk'), (self.out/'apk/control.apk', 'control.apk')]:
            self.run(['docker', 'cp', source, self.cid+':'+self.android_dir+'/'+target])
            self.dx(['chmod', '644', self.android_dir+'/'+target])
        gateway = self.owner()['NetworkSettings']['Networks']['bridge']['Gateway']
        self.container_ip = self.owner()['NetworkSettings']['Networks']['bridge']['IPAddress']
        self.fixture = Fixture(gateway, self.out/'fixture.jsonl')
        self.nonce = self.fixture.nonce.hex()
        self.start_controller(0, 'controller-root')
        if self.headers_enabled: self.start_headers()
        for role, package, apk in [('a', 'org.royd.networkprobe', 'probe.apk'), ('b', 'org.royd.networkcontrol', 'control.apk')]:
            need(not self.dx(['timeout', '10', 'pm', 'list', 'packages', package]).strip(), 'pre-existing package')
            need('Success' in self.dx(['timeout', '30', 'pm', 'install', '-t', self.android_dir+'/'+apk], 'install-'+role+'.log').splitlines(), 'APK install failed')
            self.dx(['input', 'keyevent', 'KEYCODE_WAKEUP']);self.dx(['wm', 'dismiss-keyguard'])
            launched = time.monotonic()
            self.dx(['timeout', '30', 'am', 'start', '-W', '-n', package+'/org.royd.networkprobe.QuotaProbeLauncher',
                     '--es', 'address', self.fixture.address, '--es', 'nonce', self.nonce], 'launch-'+role+'.log')
            worker = dict(directory='/data/user/0/'+package+'/files/quota-'+self.nonce, package=package,
                          step=0, launched=launched, refresh=0)
            self.register_worker(role, worker)
        self.dx(['mkdir', self.android_dir+'/system-parent']);self.dx(['chown', '1000:1000', self.android_dir+'/system-parent'])
        self.dx(['chmod', '700', self.android_dir+'/system-parent'])
        worker = dict(directory=self.android_dir+'/system-parent/probe', step=0)
        self.native = subprocess.Popen(self.java('org.royd.networkprobe.QuotaProbe', 'probe.apk',
                                       [worker['directory'], self.fixture.address, self.nonce], 1000),
                                       stdout=(self.out/'native-worker.log').open('x'), stderr=subprocess.STDOUT)
        self.register_worker('system', worker)
        self.refresh_enabled = True
        self.start_controller(self.workers['a']['ready']['uid'], 'controller-denied')
        need(len({w['ready']['uid'] for w in self.workers.values()}) == 3, 'workers share UID')
        for role, mode in [('pre', 'observe-quota-pre'), ('post', self.quota_observe_mode)]:
            directory = self.out/('observer-'+role);directory.mkdir()
            self.namespace_owner()
            process = subprocess.Popen(['nsenter', '--net=/proc/'+str(self.host_pid)+'/ns/net', str(self.out/'native/observe'),
                                        mode, self.bpf_root, self.namespace, str(self.out/'native/observe.bpf.o'), str(directory), self.fixture.address.rsplit(':', 1)[1]],
                                       stdout=(self.out/('observer-'+role+'.log')).open('x'), stderr=subprocess.STDOUT)
            self.observers[role] = process
            self.wait(lambda: (directory/'ready.json').exists() or process.poll() is not None, 5, role+' observer')
            need(process.poll() is None, 'observer load/attachment failed')
        pre = json.loads((self.out/'observer-pre/ready.json').read_text())
        post = json.loads((self.out/'observer-post/ready.json').read_text())
        self.chains = post['query']
        for d in (0, 1):
            need(len(pre['query'][d]) == 3 and pre['query'][d][0] == self.initial['production_links'][d]
                 and pre['query'][d][2] == self.initial_quota['production_links'][d], 'pre observer placement')
            need(len(self.chains[d]) == len(set(self.chains[d])) == 4
                 and self.chains[d][:3] == pre['query'][d], 'post observer placement')
        self.manifest['WORKLOAD_STATUS'] = 'fail'
        self.save('scope.json', dict(image=self.image, nonce=self.nonce, original=self.original,
                                   namespace=self.namespace, chains=self.chains, workers=self.workers))
        self.workload()

    def workload(self):
        for label, operation, value, expected, uid in [('invalid-zero', 'set', 0, errno.ERANGE, 0), ('invalid-negative', 'set', -2, errno.ERANGE, 0),
                                                       ('denied-set', 'set', 1, -1, self.workers['a']['ready']['uid']),
                                                       ('denied-remove', 'remove', 0, -1, self.workers['a']['ready']['uid'])]:
            before = self.snapshot(label+'-before')['post']['quota']
            self.restore_needed = True
            self.control(label, operation, value, expected, uid)
            need(self.snapshot(label+'-after')['post']['quota'] == before, 'quota state changed around rejected request')
        self.channels[self.workers['a']['ready']['uid']].close()
        # Baseline one-way packets in each direction, with unchanged socket identities.
        for role in self.workers:
            for op in ('send', 'receive'):
                self.flow('baseline-'+role+'-'+op, role, op, 1, 1, None)
        self.set_quota('shared-budget', 2*IP_BYTES+100)
        self.flow('shared-a-egress', 'a', 'send', 1, 1, IP_BYTES+100)
        self.flow('shared-system-ingress', 'system', 'receive', 1, 1, 100)
        self.flow('crossing-b-egress', 'b', 'send', 1, 0, 0)
        for role, op in [('a', 'receive'), ('b', 'receive'), ('system', 'send')]:
            self.flow('exhausted-'+role+'-'+op, role, op, 2, 0, 0)
        self.set_quota('exact-budget', IP_BYTES)
        self.flow('exact-b-ingress', 'b', 'receive', 1, 1, 0)
        self.flow('after-exact-a-egress', 'a', 'send', 1, 0, 0)
        self.set_quota('old-budget', 3*IP_BYTES)
        self.flow('before-update-a-egress', 'a', 'send', 1, 1, 2*IP_BYTES)
        self.set_quota('replacement-budget', IP_BYTES)
        self.flow('replacement-system-egress', 'system', 'send', 1, 1, 0)
        self.control('remove-quota', 'remove')
        self.expected_quota = self.snapshot('removed')['post']['quota']
        need(not self.expected_quota['present'], 'quota removal did not remove entry')
        self.control('remove-absent', 'remove', expected=errno.ENODEV)
        for role in self.workers:
            for op in ('send', 'receive'):
                self.flow('removed-'+role+'-'+op, role, op, 1, 1, 0)
        self.set_quota('sentinel-budget', IP_BYTES)
        self.control('sentinel-remove', 'set', -1)
        self.expected_quota = self.snapshot('sentinel-removed')['post']['quota']
        need(not self.expected_quota['present'], 'minus-one removal did not remove entry')
        self.flow('sentinel-a-egress', 'a', 'send', 1, 1, 0)
        self.flow('sentinel-system-ingress', 'system', 'receive', 1, 1, 0)
        self.save('plan.json', self.plan)
        self.manifest['WORKLOAD_STATUS'] = 'pass'

    def register_worker(self, role, worker):
        self.workers[role] = worker
        value = self.read_worker(worker, 'ready')
        uid = value['uid']
        need(value['nonce'] == self.nonce and value['remote'] == self.fixture.address
             and value['local'].rsplit(':', 1)[0] == self.container_ip, 'worker endpoint identity')
        need(value['gid'] == uid and int(value['cap_eff'], 16) == 0, 'worker privilege')
        need(10000 <= uid < 20000 and value['importance'] == 300 and '/uid_'+str(uid)+'/' in value['cgroup']
             if role != 'system' else uid == 1000 and value['importance'] == -1 and value['cgroup'].strip() == '0::/royd/init',
             'worker UID/cgroup/state')
        worker['ready'] = value
        worker['start_ticks'] = self.dx(['cat', '/proc/'+str(value['pid'])+'/stat']).rsplit(')', 1)[1].split()[19]
        need(self.dx(['stat', '-c', '%u', worker['directory']+'/ready.json']).strip() == str(uid), 'worker result ownership')
        self.save('ready-'+role+'.json', value)
        self.fixture.register(uid, value['local'])
        self.worker_identity(worker, 'ready-'+role)

    def set_quota(self, label, limit):
        before = self.snapshot(label+'-before')['post']['quota']
        self.restore_needed = True
        self.control(label, 'set', limit)
        value = self.snapshot(label+'-after')['post']['quota']
        need(value['present'] and value['limit'] == value['remaining'] == limit
             and value['generation'] > before['generation'] and value['invalid'] == value['contention'] == 0,
             'quota registration not committed')
        self.expected_quota = value

    def attempt(self, label, operation):
        try: operation()
        except Exception: self.failures.append(label+': '+traceback.format_exc())

    def archive(self, directory, name):
        # Export through Android's live private-data mount view. Preserve raw bytes.
        self.owner()
        argv = ['docker', 'exec', self.cid, 'timeout', '15', 'tar', '-C', directory, '-cf', '-', '.']
        start = time.monotonic_ns()
        with (self.out/name).open('xb') as output:
            try:
                result = subprocess.run(argv, stdout=output, stderr=subprocess.PIPE, timeout=20)
            except subprocess.TimeoutExpired as error:
                result = subprocess.CompletedProcess(argv, 124, stderr=error.stderr or b'archive command timed out')
        with (self.out/(name+'.log')).open('xb') as output: output.write(result.stderr)
        with (self.out/'commands.jsonl').open('a') as output:
            output.write(json.dumps(dict(argv=argv, status=result.returncode, output=name,
                                        start_ns=start, end_ns=time.monotonic_ns()))+'\n')
        need(result.returncode == 0, 'archive capture failed: '+directory)
        with tarfile.open(self.out/name, 'r:') as archive:
            for member in archive:
                need(not member.name.startswith('/') and '..' not in Path(member.name).parts
                     and (member.isdir() or member.isfile()), 'unexpected archive member')
                if member.isfile():
                    with archive.extractfile(member) as data:
                        remaining = member.size
                        while remaining:
                            block = data.read(min(remaining, 1024*1024))
                            need(block, 'truncated archive member')
                            remaining -= len(block)

    def finish(self):
        self.finishing = True
        self.refresh_enabled = False
        if self.restore_needed:
            self.manifest['RESTORE_STATUS'] = 'fail'
            def restore():
                self.control('restore-original', 'set', self.original['limit'])
                state = self.direct('restored-quota.json', True)['quota']
                need(state['present'] and state['limit'] == self.original['limit'], 'original quota policy not restored')
                self.restore_needed = False
                self.manifest['RESTORE_STATUS'] = 'pass'
            self.attempt('restore original quota', restore)
        elif self.original is not None:
            self.manifest['RESTORE_STATUS'] = 'pass'
        for role, worker in self.workers.items():
            def stop(role=role, worker=worker):
                if 'ready' not in worker: return
                self.command(worker, 'stop', 0)
                reply = self.read_worker(worker, 'stopped')
                need(reply['uid'] == worker['ready']['uid'] and reply['pid'] == worker['ready']['pid'], 'worker stop identity')
                if 'package' in worker:
                    self.dx(['timeout', '10', 'am', 'force-stop', worker['package']], 'stop-'+role+'.log')
                elif self.native is not None:
                    need(self.native.wait(timeout=10) == 0, 'native worker exit')
            self.attempt('stop '+role, stop)
        if self.controller_processes:
            def close_controllers():
                self.before_close_controllers()
                for channel in self.channels.values():
                    if not channel.closed: channel.close()
                need(len(self.channels) == len(self.controller_processes)
                     and all(not c.broken and c.closed for c in self.channels.values()), 'controller evidence incomplete')
                self.manifest['CONTROLLER_STATUS'] = 'pass'
            self.attempt('close controllers', close_controllers)
        for role, process in self.observers.items():
            self.manifest['DETACH_STATUS'] = 'fail'
            def detach(role=role, process=process):
                (self.out/('observer-'+role)/'stop').touch(exist_ok=False)
                need(process.wait(timeout=10) == 0, role+' observer exit')
            self.attempt('detach '+role, detach)
        if self.observers:
            def verify_detached():
                a = self.direct('detached-accounting.json')
                q = self.direct('detached-quota.json', True)
                for before, after in ((self.initial, a), (self.initial_quota, q)):
                    for key in ('ifindex', 'map_id', 'production_links', 'query'):
                        need(before[key] == after[key], 'production attachment changed after detach')
                self.manifest['DETACH_STATUS'] = 'pass'
            self.attempt('verify detachment', verify_detached)
        if self.fixture is not None:
            self.manifest['FIXTURE_STATUS'] = 'fail'
            def stop_fixture():
                self.save('fixture-final.json', self.fixture.close())
                self.manifest['FIXTURE_STATUS'] = 'pass'
            self.attempt('fixture integrity', stop_fixture)
        if self.manifest['WORKLOAD_STATUS'] == 'pass':
            self.manifest['WORKLOAD_STATUS'] = 'fail'
            def replay_packets():
                self.save('packet-replay.json', self.replay_packets())
                self.manifest['WORKLOAD_STATUS'] = 'pass'
            self.attempt('saved packet matrix', replay_packets)
        if self.header_process is not None:
            self.attempt('packet header observation', self.stop_headers)
        if self.pre:
            self.manifest['RUNTIME_STATUS'] = 'fail'
            def post():
                self.runtime('after-runtime.log')
                need(self.identity('identity-after.json') == self.initial_identity, 'Android/Docker identity changed')
                need(self.oci('oci-after.log') == self.initial_oci, 'OCI networking/qdisc changed')
                self.manifest['RUNTIME_STATUS'] = 'pass'
            self.attempt('post runtime', post)
        capture_ok = False
        if self.created:
            self.manifest['CAPTURE_STATUS'] = 'fail'
            def capture():
                nonlocal capture_ok
                self.owner()
                diagnostic_errors = []
                if self.headers_enabled and self.pre:
                    for name, args in [('resolver-query.log', ['dumpsys', 'dnsresolver', 'querylog']),
                                       ('resolver-state.log', ['dumpsys', 'dnsresolver']),
                                       ('processes.log', ['ps', '-A', '-o', 'UID,PID,NAME']),
                                       ('packages.log', ['pm', 'list', 'packages', '-U']),
                                       ('logcat-epoch.log', ['logcat', '-b', 'all', '-d', '-v', 'epoch'])]:
                        try: self.dx(['timeout', '10', *args], name)
                        except Exception: diagnostic_errors.append(traceback.format_exc())
                self.run([SCRIPTS/'container-evidence.sh', self.cid, self.out/'container'], 'capture.log')
                probe = self.run(['docker', 'exec', self.cid, 'timeout', '5', 'test', '-d', '/data/anr'], 'anr-directory.log', check=False)
                need(probe.returncode in (0, 1), 'ANR directory probe failed')
                self.save('anr-directory.json', dict(exit_status=probe.returncode, observation='available' if probe.returncode == 0 else 'unavailable'))
                if probe.returncode == 0:
                    self.archive('/data/anr', 'anr.tar')
                (self.out/'workers').mkdir()
                for role, worker in self.workers.items():
                    available = self.run(['docker', 'exec', self.cid, 'timeout', '5', 'test', '-d', worker['directory']],
                                         'worker-directory-'+role+'.log', check=False)
                    need(available.returncode in (0, 1), 'worker directory probe failed')
                    need('ready' not in worker or available.returncode == 0, 'ready worker evidence disappeared')
                    self.save('worker-directory-'+role+'.json', dict(exit_status=available.returncode,
                              observation='available' if available.returncode == 0 else 'unavailable'))
                    if available.returncode == 0:
                        self.archive(worker['directory'], 'workers/'+role+'.tar')
                self.owner()
                need(not diagnostic_errors, 'diagnostic evidence incomplete: '+repr(diagnostic_errors))
                need(self.header_process is None or self.manifest['PACKET_HEADERS_STATUS'] == 'pass',
                     'packet header evidence incomplete')
                need(not self.controller_processes or self.manifest['CONTROLLER_STATUS'] == 'pass',
                     'controller evidence incomplete')
                self.manifest['CAPTURE_STATUS'] = 'pass'
                capture_ok = True
            self.attempt('complete evidence capture', capture)
        if capture_ok and (not self.observers or self.manifest['DETACH_STATUS'] == 'pass'):
            self.manifest['CLEANUP_STATUS'] = 'fail'
            def cleanup():
                self.owner()
                self.run(['docker', 'rm', '-f', self.cid], 'container-cleanup.log')
                owner = self.run(['docker', 'volume', 'inspect', '--format', '{{index .Labels "org.royd.test.owner"}}', self.volume]).stdout.strip()
                need(owner == self.token, 'volume ownership changed')
                self.run(['docker', 'volume', 'rm', self.volume], 'volume-cleanup.log')
                self.manifest['CLEANUP_STATUS'] = 'pass'
            self.attempt('owned cleanup', cleanup)
        elif not self.created and self.volume_owned:
            def remove_unused_volume():
                owner = self.run(['docker', 'volume', 'inspect', '--format', '{{index .Labels "org.royd.test.owner"}}', self.volume]).stdout.strip()
                need(owner == self.token, 'volume ownership changed')
                self.run(['docker', 'volume', 'rm', self.volume], 'unused-volume-cleanup.log')
            self.attempt('unused volume cleanup', remove_unused_volume)
        for child in [self.native, self.header_process, *self.observers.values(), *self.controller_processes]:
            if child is not None and child.poll() is None:
                child.terminate()
                self.attempt('reap child', lambda child=child: child.wait(timeout=5))
        self.save('failures.json', self.failures)
        required = ('WORKLOAD_STATUS', 'RESTORE_STATUS', 'DETACH_STATUS', 'FIXTURE_STATUS', 'RUNTIME_STATUS', 'CAPTURE_STATUS', 'CLEANUP_STATUS', 'CONTROLLER_STATUS')
        required += self.extra_required
        if self.headers_enabled: required += ('PACKET_HEADERS_STATUS',)
        if not self.failures and all(self.manifest[k] == 'pass' for k in required): self.manifest['RESULT_STATUS'] = 'pass'
        with (self.out/'manifest.env').open('x') as f:
            for k, v in self.manifest.items(): f.write(str(k)+'='+str(v)+'\n')


def main(trial_class=Trial):
    trial = trial_class()
    def interrupted(number, frame): raise InterruptedError('signal '+str(number))
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGHUP, interrupted)
    try: trial.body()
    except BaseException: trial.failures.append('workload: '+traceback.format_exc())
    finally: trial.finish()
    print('Interface quota result:', trial.manifest['RESULT_STATUS'], 'evidence:', trial.out)
    if trial.failures: print('\n'.join(trial.failures), file=sys.stderr)
    return 0 if trial.manifest['RESULT_STATUS'] == 'pass' else 1


if __name__ == '__main__': sys.exit(main())
