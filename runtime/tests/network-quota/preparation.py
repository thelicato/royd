"""Bounded passive preparation for exact-IP quota/alert measurements."""
import ipaddress
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import time
import traceback
from socket_census import parse, MAX_SOCKETS
from packet_headers import need, publish

QUIET_SECONDS, MAX_SECONDS, INTERVAL = 10, 1200, 1
IDENTITY = ('ifindex', 'map_id', 'production_links', 'query')


def external(rows):
    # LISTEN cannot itself retain a remote close; include every other state,
    # including TIME_WAIT and inode-zero orphans. Ignore only wholly loopback flows.
    return [r for r in rows if r['state'] != 10 and not all(
        ipaddress.ip_address(r[k]['address']).is_loopback for k in ('local', 'remote'))]


def counters(value, initial):
    need(all(value[k] == initial[k] for k in IDENTITY), 'preparation accounting identity changed')
    result = value['counters']
    need(len(result) == 4 and all(type(v) is int and 0 <= v < 1 << 64 for v in result),
         'invalid preparation counters')
    return result


class Window:
    def __init__(self, initial, gateway_namespace):
        self.initial = initial
        self.gateway_namespace = gateway_namespace
        self.previous = counters(initial, initial)
        self.since = None
        self.end = None
        self.count = 0

    def add(self, sample):
        a = counters(sample['before'], self.initial)
        b = counters(sample['after'], self.initial)
        need(all(x <= y <= z for x,y,z in zip(self.previous,a,b)), 'preparation counters regressed')
        need(sample['start_ns'] <= sample['end_ns'], 'preparation clock regressed')
        need(self.end is None or self.end <= sample['start_ns'], 'preparation sample order changed')
        stable = a == b == self.previous and not external(sample['sockets'])
        tracked = sample['conntrack']
        need(tracked['namespace'] == self.gateway_namespace and 1 <= tracked['datagrams'] <= 64
             and 0 < tracked['bytes'] <= 262144 and tracked['reply_flags']
             and set(tracked['reply_flags']) <= {2,34} and len(tracked['entries']) <= 256,
             'incomplete gateway conntrack observation')
        stable = stable and not tracked['entries']
        stable = stable and sample['end_ns']-sample['start_ns'] <= 2_500_000_000 and (
            self.end is None or sample['start_ns']-self.end <= 2_500_000_000)
        self.end = sample['end_ns']
        self.previous = b
        if not stable: self.since = None;self.count = 0
        else:
            if self.since is None: self.since = sample['end_ns']
            self.count += 1
        return self.since is not None and self.count >= 11 and sample['end_ns']-self.since >= QUIET_SECONDS*1_000_000_000


def replay(directory, initial=None):
    directory = Path(directory)
    ready = json.loads((directory/'ready.json').read_text())
    result = json.loads((directory/'result.json').read_text())
    need(ready['format'] == 2 and ready['quiet_seconds'] == QUIET_SECONDS
         and 30 <= ready['deadline_seconds'] <= MAX_SECONDS, 'preparation contract changed')
    if initial is not None:
        need(ready['initial'] == initial, 'preparation differs from original accounting source')
    window = Window(ready['initial'],ready['gateway_namespace']);previous = ready['opened_ns'];complete = False;count = 0
    for line in (directory/'samples.jsonl').read_text().splitlines():
        row = json.loads(line);count += 1
        need(not complete and row['sequence'] == count and previous <= row['start_ns']
             <= row['end_ns'] <= ready['opened_ns']+ready['deadline_seconds']*1_000_000_000,
             'preparation sequence/deadline changed')
        previous = row['end_ns'];complete = window.add(row)
    need(complete and count == result['samples'] and result['status'] == 'pass' and not result['errors']
         and result['namespace'] == ready['namespace'] and result['ifindex'] == ready['initial']['ifindex']
         and result['quiet_since_ns'] == window.since and previous <= result['closed_ns'],
         'incomplete preparation evidence')
    return dict(status='pass', samples=count, quiet_since_ns=window.since,
                elapsed_seconds=(previous-ready['opened_ns'])/1e9)


def replay_for_scope(directory, scope):
    directory = Path(directory)
    required = scope.get('preparation_required', False)
    need(type(required) is bool, 'invalid preparation scope')
    if 'preparation_required' in scope:
        need(required == (scope['network_mode'] == 'isolated'), 'preparation mode changed')
    manifest = directory/'manifest.env'
    if manifest.exists() and set(manifest.read_text().splitlines()) & {
            'ROYD_QUOTA_EVIDENCE_FORMAT=5','ROYD_QUOTA_EVIDENCE_FORMAT=6'}:
        need(required, 'missing required preparation scope')
    if required:
        load = lambda name: json.loads((directory/name).read_text())
        need(load('preparation-assessment.json') == replay(directory/'preparation',load('initial-accounting.json')),
             'saved preparation assessment changed')


class Gateway:
    def __init__(self, path, namespace, android, host):
        self.path,self.namespace,self.android,self.host = path,namespace,android,host

    def __enter__(self):
        need(self.namespace not in (self.android,self.host), 'private gateway namespace required')
        self.fd = os.open(self.path,os.O_RDONLY|os.O_CLOEXEC)
        try: self.identity()
        except BaseException: os.close(self.fd);raise
        return self

    def __exit__(self, *args):
        os.close(self.fd)

    def identity(self):
        need(os.readlink(self.path) == os.readlink('/proc/self/fd/'+str(self.fd)) == self.namespace,
             'gateway namespace identity changed')

    def read(self):
        self.identity()
        command = ['nsenter','--net=/proc/self/fd/'+str(self.fd),sys.executable,'-B',
                   str(Path(__file__).with_name('conntrack.py')),self.namespace,self.android,self.host]
        result = subprocess.run(command,pass_fds=(self.fd,),text=True,stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE,timeout=4)
        need(result.returncode == 0, 'gateway conntrack read failed: '+result.stderr[-1500:])
        self.identity()
        return json.loads(result.stdout)


def observe(directory, namespace, parent, binary, bpf_root, initial, seconds, gateway_path, gateway_namespace):
    need(30 <= seconds <= MAX_SECONDS, 'preparation deadline must be 30 to 1200 seconds')
    def identity():
        need(os.readlink('/proc/self/ns/net') == namespace
             and namespace != os.readlink('/proc/'+str(parent)+'/ns/net'), 'private preparation namespace required')
        need(socket.if_nametoindex('eth0') == initial['ifindex'] > 1, 'preparation eth0 changed')
    identity()
    with Gateway(gateway_path,gateway_namespace,namespace,os.readlink('/proc/'+str(parent)+'/ns/net')) as gateway:
        return collect(directory,namespace,binary,bpf_root,initial,seconds,identity,gateway)


def collect(directory, namespace, binary, bpf_root, initial, seconds, identity, gateway):
    opened = time.monotonic_ns();deadline = opened+seconds*1_000_000_000
    window = Window(initial,gateway.namespace);samples = 0;errors = [];complete = False
    publish(directory,'ready',dict(format=2,namespace=namespace,initial=initial,quiet_seconds=QUIET_SECONDS,
                                   gateway_namespace=gateway.namespace,
                                   deadline_seconds=seconds,opened_ns=opened))
    def inspect():
        process = subprocess.run([str(binary),'inspect',str(bpf_root),namespace],text=True,
                                 stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=5)
        need(process.returncode == 0, 'preparation accounting read failed: '+process.stderr[-1000:])
        return json.loads(process.stdout)
    try:
        with (directory/'samples.jsonl').open('x') as output:
            while not complete:
                start = time.monotonic_ns()
                need(start < deadline and samples <= MAX_SECONDS+1, 'preparation deadline exceeded')
                identity();before = inspect();rows = []
                for family,name in ((4,'tcp'),(6,'tcp6')):
                    try: text = Path('/proc/thread-self/net/'+name).read_text()
                    except FileNotFoundError:
                        need(family == 6, 'preparation IPv4 table unavailable');continue
                    rows.extend(parse(text,family))
                need(len(rows) <= MAX_SOCKETS, 'preparation socket bound exceeded')
                tracked = gateway.read()
                after = inspect();identity();end = time.monotonic_ns();samples += 1
                sample = dict(sequence=samples,start_ns=start,end_ns=end,before=before,after=after,sockets=rows,
                              conntrack=tracked)
                output.write(json.dumps(sample)+'\n');output.flush()
                need(end <= deadline, 'preparation read exceeded deadline')
                complete = window.add(sample)
                if not complete: time.sleep(min(INTERVAL,max(0,(deadline-time.monotonic_ns())/1e9)))
    except BaseException: errors.append(traceback.format_exc())
    publish(directory,'result',dict(status='pass' if complete and not errors else 'fail',errors=errors,
            namespace=namespace,ifindex=initial['ifindex'],samples=samples,quiet_since_ns=window.since,
            closed_ns=time.monotonic_ns()))
    return 0 if complete and not errors else 1


if __name__ == '__main__':
    need(len(sys.argv) == 10, 'usage: preparation.py OUTPUT NETNS PARENT_PID INSPECTOR BPF_ROOT INITIAL SECONDS GATEWAY_PATH GATEWAY_NETNS')
    sys.exit(observe(Path(sys.argv[1]),sys.argv[2],int(sys.argv[3]),Path(sys.argv[4]),Path(sys.argv[5]),
                     json.loads(Path(sys.argv[6]).read_text()),int(sys.argv[7]),sys.argv[8],sys.argv[9]))
