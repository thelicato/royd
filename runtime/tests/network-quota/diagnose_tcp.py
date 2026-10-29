"""Observe ordinary Android startup/runtime TCP lifecycles, without quota changes."""
import json
import os
from pathlib import Path
import shlex
import signal
import subprocess
import sys
import time
import traceback
from run import Trial, ROOT, SCRIPTS
from assess import need


def analyse(directory):
    directory=Path(directory)
    packets=[json.loads(r) for r in (directory/'headers/headers.jsonl').read_text().splitlines()]
    samples=[json.loads(r) for r in (directory/'census/samples.jsonl').read_text().splitlines()]
    need(samples and [s['sequence'] for s in samples]==list(range(1,len(samples)+1)), 'census sequence gap')
    need(all(a['end_ns']<=b['start_ns'] for a,b in zip(samples,samples[1:])), 'census time regression')
    def key(r):
        return (r['local']['address'],r['local']['port'],r['remote']['address'],r['remote']['port'])
    flows={}
    for packet in packets:
        if packet.get('protocol')!=6 or packet.get('direction')!='ingress' or not packet.get('tcp_flags',0)&1:continue
        flow=(packet['destination'],packet['destination_port'],packet['source'],packet['source_port'])
        flows.setdefault(flow,[]).append(packet)
    results=[]
    for flow,fins in flows.items():
        history=[];processes=[]
        for sample in samples:
            rows=[r for r in sample['sockets'] if key(r)==flow]
            if not rows:continue
            history.append(dict(start_ns=sample['start_ns'],end_ns=sample['end_ns'],sockets=rows))
            inodes={r['inode'] for r in rows if r['inode']}
            if sample['owners']:
                for process in sample['owners']['processes']:
                    matched=[r for r in process['sockets'] if r['inode'] in inodes]
                    if matched:processes.append(dict(start_ns=sample['start_ns'],end_ns=sample['end_ns'],
                                                    process=dict(process,sockets=matched)))
        outgoing=[r for r in packets if r.get('protocol')==6 and r.get('direction')=='egress'
                  and (r['source'],r['source_port'],r['destination'],r['destination_port'])==flow
                  and r['received_monotonic_ns']>=fins[0]['received_monotonic_ns']]
        results.append(dict(flow=flow,fin_packets=fins,socket_history=history,observed_fd_holders=processes,
                            outgoing_after_first_fin=outgoing))
    return dict(scope='read-only TCP lifecycle observation, not quota acceptance',fin_flows=results,
                samples=len(samples),max_sample_gap_ns=max((b['start_ns']-a['end_ns'] for a,b in zip(samples,samples[1:])),default=0),
                limits='Discrete socket and FD observations are time-bounded evidence, not atomic packet-to-process attribution. '
                       'Preserve historical connections, inode-zero states and ambiguity; no unseen owner or drop cause is inferred.')


class Probe(Trial):
    def __init__(self):
        super().__init__()
        need(self.link is not None,'TCP lifecycle probe requires isolated mode')
        self.seconds=int(os.environ.get('ROYD_TCP_OBSERVE_SECONDS','240'))
        need(60<=self.seconds<=300,'observation must be 60 to 300 seconds')
        self.monitors={};self.boot_ready=False
        self.manifest=dict(ROYD_TCP_LIFECYCLE_EVIDENCE_FORMAT=1,RESULT_STATUS='fail',IMAGE_ID='unknown',
                           CONTAINER=self.container,VOLUME=self.volume,NETWORK_MODE='isolated-routed-ipv4',
                           BOOT_STATUS='not-tested',SECURITY_STATUS='not-tested',RUNTIME_BEFORE_STATUS='not-tested',
                           RUNTIME_AFTER_STATUS='not-tested',HEADERS_STATUS='not-tested',CENSUS_STATUS='not-tested',
                           OBSERVATION_STATUS='not-tested',CONFIG_STATUS='not-tested',CAPTURE_STATUS='not-tested',
                           CLEANUP_STATUS='not-tested',ISOLATION_STATUS='not-tested',ISOLATION_CLEANUP_STATUS='not-tested',
                           REQUESTED_OBSERVATION_SECONDS=self.seconds)

    def start_monitors(self):
        holder=self.link.holders['android'];self.link.owner('android')
        self.namespace=holder['namespace'];index=self.link.frozen['identity']['android_link'][0]
        for role,script in [('headers','packet_headers.py'),('census','socket_census.py')]:
            directory=self.out/role;directory.mkdir()
            command=['nsenter','--net=/proc/'+str(holder['pid'])+'/ns/net','python3','-B',
                     str(ROOT/'runtime/tests/network-quota'/script),str(directory),self.namespace,str(index),str(os.getpid())]
            self.save(role+'-command.json',command)
            child=subprocess.Popen(command,stdout=(self.out/(role+'.log')).open('x'),stderr=subprocess.STDOUT)
            self.monitors[role]=child
            self.wait(lambda:(directory/'ready.json').exists() or child.poll() is not None,5,role+' ready')
            need(child.poll() is None,role+' exited before ready')
            ready=json.loads((directory/'ready.json').read_text())
            need(ready['namespace']==self.namespace and ready['ifindex']==index and ready['pid']==child.pid
                 and os.readlink('/proc/'+str(child.pid)+'/ns/net')==self.namespace,role+' identity')
        self.link.owner('android')

    def body(self):
        need(os.environ.get('DOCKER_HOST','unix:///var/run/docker.sock').startswith('unix://'),'local Docker required')
        need(self.run(['docker','context','inspect','--format','{{.Endpoints.docker.Host}}']).stdout.strip().startswith('unix://'),'local Docker context required')
        image=json.loads(self.run(['docker','image','inspect',self.image]).stdout)[0]
        self.image=image['Id'];self.manifest['IMAGE_ID']=self.image
        need([image['Config']['Labels'].get('org.royd.'+k) for k in ('android-version','arch','image-profile','hal-profile','graphics-backend')]
             ==['15','x86_64','standard','graphical','software'],'Android15 baseline required')
        need(self.run(['docker','inspect',self.container],check=False).returncode!=0,'existing container')
        need(self.run(['docker','volume','inspect',self.volume],check=False).returncode!=0,'existing volume')
        self.run(['docker','volume','create','--label','org.royd.test.owner='+self.token,self.volume],'volume-create.log')
        self.volume_owned=True
        need(self.run(['docker','volume','inspect','--format','{{index .Labels "org.royd.test.owner"}}',self.volume]).stdout.strip()==self.token,'volume ownership')
        self.link.setup();self.start_monitors()
        args=[]
        for helper,options in [('security-args.sh',['privileged']),('container-args.sh',[])]:
            args+=shlex.split(self.run([SCRIPTS/helper,*options]).stdout)
        profile=shlex.split(self.run([SCRIPTS/'profile.sh','default'],env=dict(os.environ,ROYD_RESOURCE_PROFILE='low-memory')).stdout)
        network='container:'+self.link.holders['android']['id']
        self.cid=self.run(['docker','create',*args,'--name',self.container,'--network',network,
                          '--label','org.royd.test=network-quota','--label','org.royd.test.owner='+self.token,
                          '-v',self.volume+':/data',self.image,*profile],'create.log').stdout.strip()
        self.created=True;self.owner();self.run(['docker','start',self.cid],'start.log')
        self.manifest['BOOT_STATUS']='fail'
        self.run([SCRIPTS/'wait-for-boot.sh',self.cid,'180'],'boot.log',timeout=210,
                 env=dict(os.environ,ROYD_BOOT_WAIT_MARKER='ROYD: using delegated cgroup v2 subtree'))
        self.run([SCRIPTS/'wait-for-health.sh',self.cid,'240'],'health.log',timeout=250)
        self.manifest['BOOT_STATUS']='pass';self.boot_ready=True
        self.manifest['SECURITY_STATUS']='fail'
        self.run([SCRIPTS/'assert-security.sh',self.cid,'privileged'],'security.log')
        self.manifest['SECURITY_STATUS']='pass';self.manifest['RUNTIME_BEFORE_STATUS']='fail'
        self.runtime('before-runtime.log');self.manifest['RUNTIME_BEFORE_STATUS']='pass'
        self.initial_identity=self.identity('identity-before.json');self.initial_oci=self.oci('oci-before.log')
        self.pre=True;self.manifest['OBSERVATION_STATUS']='fail'
        start=time.monotonic_ns();deadline=time.monotonic()+self.seconds
        self.save('observation-start.json',dict(monotonic_ns=start,seconds=self.seconds))
        while time.monotonic()<deadline:
            need(all(child.poll() is None for child in self.monitors.values()),'observer exited early')
            time.sleep(.2)
        self.save('observation-end.json',dict(monotonic_ns=time.monotonic_ns()))
        self.manifest['OBSERVATION_STATUS']='pass'

    def finish(self):
        if self.pre:
            self.manifest['RUNTIME_AFTER_STATUS']='fail'
            def post():
                self.runtime('after-runtime.log')
                need(self.identity('identity-after.json')==self.initial_identity,'Android/Docker identity changed')
                need(self.oci('oci-after.log')==self.initial_oci,'OCI configuration changed')
                self.manifest['RUNTIME_AFTER_STATUS']='pass'
            self.attempt('post runtime',post)
        for role,child in self.monitors.items():
            key='HEADERS_STATUS' if role=='headers' else 'CENSUS_STATUS';self.manifest[key]='fail'
            def stop(role=role,child=child,key=key):
                self.link.owner('android');(self.out/role/'stop').touch(exist_ok=False)
                need(child.wait(timeout=10)==0,role+' exit')
                result=json.loads((self.out/role/'result.json').read_text())
                need(result['status']=='pass' and not result['errors'] and result['namespace']==self.namespace,role+' incomplete')
                if role=='headers':need(result['packets']==result['frames'] and result['drops']==0,'capture loss')
                self.manifest[key]='pass'
            self.attempt('stop '+role,stop)
        if self.link.frozen is not None:
            self.manifest['CONFIG_STATUS']='fail'
            def configuration():self.link.snapshot('isolated-link-after');self.manifest['CONFIG_STATUS']='pass'
            self.attempt('configuration',configuration)
        if all(self.manifest[k]=='pass' for k in ('HEADERS_STATUS','CENSUS_STATUS')):
            self.attempt('saved analysis',lambda:self.save('analysis.json',analyse(self.out)))
        capture=False
        if self.created:
            self.manifest['CAPTURE_STATUS']='fail'
            def evidence():
                nonlocal capture
                self.owner()
                try:
                    probe=self.run(['docker','exec',self.cid,'timeout','5','test','-d','/data/anr'],'anr-directory.log',check=False)
                    need(probe.returncode in (0,1),'ANR directory probe failed')
                    self.save('anr-directory.json',dict(status='available' if probe.returncode==0 else 'unavailable'))
                    if probe.returncode==0:self.archive('/data/anr','anr.tar')
                    if self.boot_ready:
                        for label,args in [('policy',['dumpsys','netpolicy']),('processes',['ps','-A','-o','UID,PID,NAME']),
                                           ('packages',['pm','list','packages','-U']),('resolver',['dumpsys','dnsresolver','querylog'])]:
                            self.dx(['timeout','10',*args],label+'.log')
                finally:
                    self.owner();self.run([SCRIPTS/'container-evidence.sh',self.cid,self.out/'container'],'capture.log')
                self.owner();self.manifest['CAPTURE_STATUS']='pass';capture=True
            self.attempt('full evidence',evidence)
        for child in self.monitors.values():
            if child.poll() is None:child.terminate();self.attempt('reap observer',lambda child=child:child.wait(timeout=5))
        complete=all(self.manifest[k]=='pass' for k in ('HEADERS_STATUS','CENSUS_STATUS','CONFIG_STATUS'))
        if self.created and capture and complete:
            self.manifest['CLEANUP_STATUS']='fail'
            def cleanup():
                self.owner();self.run(['docker','rm','-f',self.cid],'container-cleanup.log')
                need(self.run(['docker','volume','inspect','--format','{{index .Labels "org.royd.test.owner"}}',self.volume]).stdout.strip()==self.token,'volume owner changed')
                self.run(['docker','volume','rm',self.volume],'volume-cleanup.log');self.manifest['CLEANUP_STATUS']='pass'
            self.attempt('owned cleanup',cleanup)
        elif not self.created and self.volume_owned:
            def unused():
                need(self.run(['docker','volume','inspect','--format','{{index .Labels "org.royd.test.owner"}}',self.volume]).stdout.strip()==self.token,'volume owner changed')
                self.run(['docker','volume','rm',self.volume],'unused-volume-cleanup.log')
            self.attempt('unused volume',unused)
        if not self.created or self.manifest['CLEANUP_STATUS']=='pass':self.attempt('holder cleanup',self.link.cleanup)
        self.save('failures.json',self.failures)
        keys=[k for k in self.manifest if k.endswith('_STATUS') and k!='RESULT_STATUS']
        if not self.failures and all(self.manifest[k]=='pass' for k in keys):self.manifest['RESULT_STATUS']='pass'
        with (self.out/'manifest.env').open('x') as f:
            for k,v in self.manifest.items():f.write(str(k)+'='+str(v)+'\n')


def main():
    probe=Probe()
    def interrupted(number,frame):raise InterruptedError('signal '+str(number))
    signal.signal(signal.SIGTERM,interrupted);signal.signal(signal.SIGHUP,interrupted)
    try:probe.body()
    except BaseException:probe.failures.append(traceback.format_exc())
    finally:probe.finish()
    print('TCP lifecycle diagnostic:',probe.manifest['RESULT_STATUS'],'evidence:',probe.out)
    return 0 if probe.manifest['RESULT_STATUS']=='pass' else 1


if __name__=='__main__':sys.exit(main())
