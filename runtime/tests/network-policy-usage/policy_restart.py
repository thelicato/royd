"""Fresh finite-policy restoration and real Binder lifetime acceptance."""
from pathlib import Path
import hashlib,json,os,subprocess,sys,time,traceback
ROOT=Path(__file__).resolve().parents[3]
sys.path[:0]=[str(ROOT/'runtime/tests/network-policy-usage'),str(ROOT/'runtime/tests/network-restart'),str(ROOT/'runtime/tests/network-quota')]
from policy_limit import PolicyLimitTrial
from service_restart import ServiceRestartTrial
from assess_restart import assess as assess_backend
from assess import need
from run import main,SCRIPTS,MAXIMUM


class PolicyRestartTrial(PolicyLimitTrial):
    result_name='Finite framework policy service restart'
    extra_required=PolicyLimitTrial.extra_required+ServiceRestartTrial.extra_required+('POLICY_RECOVERY_STATUS','LISTENER_RECOVERY_STATUS','RESTART_PACKET_STATUS')
    persistence=ServiceRestartTrial.persistence
    validate_runtime_identity=ServiceRestartTrial.validate_runtime_identity

    def __init__(self):
        super().__init__()
        self.service=os.environ.get('ROYD_NETWORK_RESTART_SERVICE','netd')
        need(self.service in ('netd','zygote'),'Invalid restart service')
        self.recovered_identity=None;self.restart_process=None;self.restart_output=None
        self.first_phase=True;self.restore_sequence=0;self.hook=None;self.recovery_packet_safe=True;self.recovery_process=None;self.recovery_log=None
        self.manifest.update(ROYD_POLICY_RESTART_EVIDENCE_FORMAT=1,RESTART_SERVICE=self.service,SERVICE_RESTART_STATUS='not-tested',
            NETWORK_STATE_STATUS='not-tested',PERSISTENCE_STATUS='not-tested',POWER_STATUS='not-tested',
            POLICY_RECOVERY_STATUS='not-tested',LISTENER_RECOVERY_STATUS='not-tested',RESTART_PACKET_STATUS='not-tested')

    def restore_first_policy(self):
        if not self.policy_touched:return
        self.restore_sequence+=1;label='restart-restore-'+str(self.restore_sequence)
        self.manifest['POLICY_RESTORE_STATUS']='fail'
        result=self.policy(label,'remove',self.policy_limit)
        need(result['policies']==[],'Owned finite policy removal failed')
        rows=[]
        def ready():
            state=self.direct(label+'-'+str(len(rows))+'.json',True);rows.append(state)
            q=state['quota']
            return q['present'] and q['limit']==MAXIMUM and q['invalid']==q['contention']==0
        try:self.wait(ready,10,'Restored default quota before traced runtime check')
        finally:self.save(label+'-samples.json',rows)
        self.capture_policy(label+'-netpolicy.xml')
        self.policy_touched=False;self.manifest['POLICY_RESTORE_STATUS']='pass'

    def release_runtime(self):
        if self.hook is not None and (self.hook/'ready.json').exists() and not (self.hook/'continue').exists():
            need(not self.policy_touched,'Do not run the unlimited-policy runtime gate before restoration')
            with (self.hook/'continue.tmp').open('x') as f:f.write(self.cid+'\n')
            os.link(self.hook/'continue.tmp',self.hook/'continue');(self.hook/'continue.tmp').unlink()

    def reap_restart(self):
        if self.restart_process is None:return
        status=self.restart_process.wait(timeout=210)
        if self.restart_output and not self.restart_output.closed:self.restart_output.close()
        path=self.out/'restart-command-result.json'
        if not path.exists():self.save(path.name,dict(status=status,end_ns=time.monotonic_ns()))
        need(status==0,'Traced restart/runtime helper failed')
        self.manifest.update(SERVICE_RESTART_STATUS='pass',POWER_STATUS='pass')

    def prepare_container(self):
        super().prepare_container()
        self.run(['go','build','-trimpath','-o',self.out/'restart-packet',ROOT/'runtime/tests/network-policy-usage/burst.go'],
                 'restart-packet-build.log',timeout=120,env=dict(os.environ,CGO_ENABLED='0',GOOS='linux',GOARCH='amd64'))
        self.run(['docker','cp',self.out/'restart-packet',self.cid+':'+self.android_dir+'/restart-packet'],'restart-packet-copy.log')
        self.dx(['chmod','755',self.android_dir+'/restart-packet'])
        need(self.dx(['sha256sum',self.android_dir+'/restart-packet']).split()[0]
             ==hashlib.sha256((self.out/'restart-packet').read_bytes()).hexdigest(),'Native restart binary copy differs')
        self.manifest.update(WORKLOAD_STATUS='fail',SERVICE_RESTART_STATUS='fail',POWER_STATUS='fail',
                             POLICY_RECOVERY_STATUS='fail',LISTENER_RECOVERY_STATUS='fail')
        self.dx(['sh','-ec',r'''printf '%s\n' "$1" > /data/local/tmp/royd-service-restart
settings put global royd_service_restart "$1"
n=0; until grep -Fq "$1" /data/system/users/0/settings_global.xml; do n=$((n+1)); [ "$n" -lt 10 ]; sleep 1; done
sync''','sh',self.token],'seed.log')
        persistence=self.persistence('persistence-before.log')
        before=dict(accounting=self.direct('backend-before-accounting.json'),quota=self.direct('backend-before-quota.json',True))
        old=self.start_controller(0,'controller-before-restart')
        need(old.request('listen')==dict(listening=True),'Old listener registration')
        listener=old.request('listener-status');self.save('restart-listener-before.json',listener)
        need(listener['netd_alive'] and listener['deaths']==0 and listener['uid']==0,'Old listener unavailable')
        for label in ('first','second'):
            text=self.dx(['timeout','30','dumpsys','netstats','--poll'],'persist-'+label+'.log')
            need(text.splitlines()==['Forced poll'],'Stock forced persistence failed')
        baseline=self.policy('restart-baseline','inspect')
        need(baseline['policies']==[] and baseline['recorded_bytes']>0,'Initial finite policy/recorded history')
        headroom=8*1024*1024;self.policy_limit=baseline['recorded_bytes']+headroom;self.policy_touched=True
        installed=self.policy('restart-installed','set',self.policy_limit);samples=[]
        def ready():
            q=self.direct('restart-install-'+str(len(samples))+'.json',True);samples.append(q)
            return q['quota']['present'] and 0<q['quota']['limit']<=headroom
        try:self.wait(ready,10,'Finite recorded-usage deduction before restart')
        finally:self.save('restart-install-samples.json',samples)
        self.capture_policy('restart-installed-netpolicy.xml')
        self.dx(['timeout','20','dumpsys','netstats','--full'],'netstats-before.log')
        self.hook=self.out/'runtime-hook';self.hook.mkdir();directory=self.out/'restart';directory.mkdir()
        env=dict(os.environ,ROYD_RESTART_ASSERT_RUNNER=str(SCRIPTS/'network-policy-restart-runtime.py'),
            ROYD_POLICY_RESTART_HOOK=str(self.hook),ROYD_POLICY_RESTART_CID=self.cid,
            ROYD_HAL_PROFILE='graphical',ROYD_GRAPHICS_BACKEND='software',ROYD_RESOURCE_PROFILE='low-memory')
        args=[str(SCRIPTS/'framework-restart.sh'),self.cid,str(directory),'180',self.service]
        self.save('restart-command.json',dict(argv=args,hook=str(SCRIPTS/'network-policy-restart-runtime.py'),start_ns=time.monotonic_ns()))
        self.restart_output=(self.out/'restart.log').open('xb')
        self.restart_process=subprocess.Popen(args,env=env,stdout=self.restart_output,stderr=subprocess.STDOUT)
        finite=None;failure=None
        try:
            self.wait(lambda:(self.hook/'ready.json').exists() or self.restart_process.poll() is not None,230,'Framework recovery before policy observation')
            need((self.hook/'ready.json').exists(),'Restart failed before readiness')
            need(json.loads((self.hook/'ready.json').read_text())['cid']==self.cid,'Hook ownership changed')
            self.recovered_identity=self.identity('identity-ready.json')
            query=self.policy('restart-recovered','inspect')
            recovered=self.direct('finite-recovered-quota.json',True)
            death=old.request('listener-status');self.save('restart-listener-after.json',death)
            self.capture_policy('restart-recovered-netpolicy.xml')
            self.dx(['timeout','20','dumpsys','netstats','--full'],'netstats-recovered.log')
            self.dx(['timeout','15','dumpsys','network_management'],'nms-recovered.log')
            self.dx(['timeout','15','dumpsys','netd'],'netd-recovered.log')
            self.dx(['timeout','15','dumpsys','netpolicy'],'npm-recovered.log')
            finite=dict(nonce=self.nonce,headroom=headroom,absolute_limit=self.policy_limit,baseline=baseline,
                installed=installed,before=samples[-1],query=query,after=recovered,listener_before=listener,
                listener_after=death)
            self.save('finite-restart-initial-case.json',finite)
            self.exercise_recovery(finite,old)
        except BaseException:failure=traceback.format_exc()
        finally:
            self.restore_first_policy();self.release_runtime();self.reap_restart()
        need(failure is None,'Finite recovery observation failed: '+str(failure))
        current=self.identity('identity-recovered.json')
        after=dict(accounting=self.direct('backend-after-accounting.json'),quota=self.direct('backend-after-quota.json',True))
        backend=dict(service=self.service,identity_before=self.initial_identity,identity_after=current,
            host_init_before=self.host_pid,host_init_after=self.owner()['State']['Pid'],before=before,after=after,
            token=self.token,persistence_before=persistence,persistence_after=self.persistence('persistence-after.log'))
        self.save('restart-case.json',backend);self.save('restart-assessment.json',assess_backend(backend))
        self.recovered_identity=current;self.manifest.update(NETWORK_STATE_STATUS='pass',PERSISTENCE_STATUS='pass')
        from assess_policy_restart import assess
        self.save('finite-restart-case.json',finite)
        self.save('finite-restart-assessment.json',assess(finite))
        self.manifest.update(POLICY_RECOVERY_STATUS='pass',LISTENER_RECOVERY_STATUS='pass',RESTART_PACKET_STATUS='pass')
        self.save('restart-fixture-final.json',self.fixture.close())
        (self.out/'fixture.jsonl').rename(self.out/'restart-fixture.jsonl')
        # Give the exact packet matrix its own nonce/ledger and fresh listener.
        from fixture import Fixture
        from isolated import GATEWAY
        gateway=self.link.holders['gateway']
        self.fixture=Fixture(GATEWAY,self.out/'fixture.jsonl','/proc/'+str(gateway['pid'])+'/ns/net',gateway['namespace'])
        self.nonce=self.fixture.nonce.hex()
        self.first_phase=False

    def exercise_recovery(self,case,old):
        from assess_policy_restart import assess_initial
        assess_initial(case)
        old.close();self.channels['before-restart']=self.channels.pop(0)
        fresh=self.start_controller(0,'controller-recovered')
        need(fresh.request('listen')==dict(listening=True),'Fresh listener registration')
        case['fresh_listener_before']=fresh.request('listener-status')
        self.save('restart-fresh-listener-before.json',case['fresh_listener_before'])
        self.manifest['RESTART_PACKET_STATUS']='fail';self.recovery_packet_safe=False
        path=self.out/'restart-packet.log';self.recovery_log=path.open('xb')
        args=['docker','exec','-i','--user','1001:1001',self.cid,'timeout','10',
              self.android_dir+'/restart-packet',self.nonce,self.fixture.address,'single']
        self.save('restart-packet-command.json',args)
        self.recovery_process=subprocess.Popen(args,stdin=subprocess.PIPE,stdout=self.recovery_log,stderr=subprocess.STDOUT)
        self.wait(lambda:path.read_bytes().endswith(b'\n') or self.recovery_process.poll() is not None,5,'Native restart packet barrier')
        need(self.recovery_process.poll() is None,'Native restart worker failed')
        rows=[json.loads(line) for line in path.read_text().splitlines()]
        need(len(rows)==1 and rows[0]['event']=='ready','Native restart readiness shape')
        packet=rows[0];pid=packet['pid']
        need(packet['uid']==packet['gid']==1001 and int(packet['cap_eff'],16)==0 and packet['nonce']==self.nonce
             and packet['remote']==self.fixture.address and packet['local'].rsplit(':',1)[0]==self.container_ip,'Native restart worker scope')
        self.recovery_start_ticks=self.dx(['cat','/proc/'+str(pid)+'/stat'],'restart-packet-stat.log').rsplit(')',1)[1].split()[19]
        self.fixture.register(1001,packet['local']);case['packet_ready']=packet
        self.save('restart-packet-ready.json',packet)
        self.recovery_process.stdin.write((self.nonce+'\n').encode());self.recovery_process.stdin.flush()
        self.stop_recovery_packet()
        rows=[json.loads(line) for line in path.read_text().splitlines()]
        need(len(rows)==2 and rows[-1]['event']=='finished','Native restart completion shape')
        case['packet']=rows[-1];self.save('restart-packet.json',case['packet'])
        samples=[]
        def ready():
            query=self.policy('restart-auto-'+str(len(samples)),'inspect')
            state=self.direct('restart-auto-'+str(len(samples))+'-quota.json',True)
            check=self.policy('restart-auto-'+str(len(samples))+'-check','inspect')
            samples.append(dict(query=query,quota=state,check=check))
            q=state['quota']
            return query['recorded_bytes']==check['recorded_bytes'] and q['present'] \
                and q['limit']==max(1,self.policy_limit-query['recorded_bytes']) and 1<q['limit']<=case['headroom']
        try:self.wait(ready,5,'Automatic calculated allowance after the real restart packet')
        finally:self.save('restart-automatic-samples.json',samples)
        case['automatic']=samples[-1];case['callbacks']=fresh.request('callbacks')
        case['fresh_listener_after']=fresh.request('listener-status')
        case['readiness']=self.dx(['timeout','15','dumpsys','netpolicy'],'npm-automatic.log')
        case['fixture']=self.fixture.records()
        self.save('restart-fresh-listener-after.json',case['fresh_listener_after'])
        self.save('restart-callbacks.json',case['callbacks'])
        self.capture_policy('restart-automatic-netpolicy.xml')
        fresh.close();self.channels['after-restart']=self.channels.pop(0)

    def replay_packets(self):
        need(len({self.channels[k].hello['pid'] for k in (0,'before-restart','after-restart')})==3,'Fresh client PID reused')
        from assess_policy_restart import replay
        return dict(backend=assess_backend(json.loads((self.out/'restart-case.json').read_text())),
            recovery=replay(self.out),packets=super().replay_packets())

    def stop_recovery_packet(self):
        if self.recovery_process is None:return
        if self.recovery_process.stdin and not self.recovery_process.stdin.closed:self.recovery_process.stdin.close()
        status=self.recovery_process.wait(timeout=12)
        if self.recovery_log and not self.recovery_log.closed:self.recovery_log.close()
        need(status==0,'Native recovery packet did not complete')
        self.recovery_packet_safe=True

    def finish(self):
        self.attempt('complete native recovery packet',self.stop_recovery_packet)
        if self.first_phase:
            self.attempt('restore pre-restart owned policy',self.restore_first_policy)
        self.attempt('release traced post-runtime gate',self.release_runtime)
        self.attempt('complete traced restart helper',self.reap_restart)
        super().finish()

    def before_owned_cleanup(self):
        need(self.recovery_packet_safe,'Unfinished native recovery packet requires retained resources')
        need(self.restart_process is None or self.restart_process.poll() is not None,'Unfinished restart helper requires retained resources')
        super().before_owned_cleanup()

if __name__=='__main__':sys.exit(main(PolicyRestartTrial))
