"""Framework-owned finite-quota continuity with a bounded native UDP stream."""
from pathlib import Path
import hashlib,json,os,subprocess,sys,time
ROOT=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(ROOT/'runtime/tests/network-quota'))
from policy_usage import PolicyUsageTrial
from run import main
from assess import need,assess_flow
from preparation import replay_for_scope
from assess_policy_continuity import assess

class ContinuityTrial(PolicyUsageTrial):
    result_name='Framework quota replacement continuity'
    extra_required=PolicyUsageTrial.extra_required+('CONTINUITY_STATUS','NATIVE_CLEANUP_STATUS','AUTOMATIC_STATS_STATUS')
    def __init__(self):
        super().__init__();self.burst_process=None;self.burst_log=None;self.burst_ready=None;self.burst_exited=False
        self.manifest.update(CONTINUITY_STATUS='not-tested',NATIVE_CLEANUP_STATUS='not-tested',AUTOMATIC_STATS_STATUS='not-tested')
    def prepare_container(self):
        super().prepare_container()
        self.run(['go','version'],'burst-go-version.log')
        self.burst_binary=self.out/'native/policy-burst'
        self.run(['go','build','-trimpath','-o',self.burst_binary,ROOT/'runtime/tests/network-policy-usage/burst.go'],
                 'burst-build.log',timeout=120,env=dict(os.environ,CGO_ENABLED='0',GOOS='linux',GOARCH='amd64'))
        self.run(['docker','cp',self.burst_binary,self.cid+':'+self.android_dir+'/burst'],'burst-copy.log')
        self.dx(['chmod','755',self.android_dir+'/burst'])
        need(self.dx(['sha256sum',self.android_dir+'/burst']).split()[0]==hashlib.sha256(self.burst_binary.read_bytes()).hexdigest(),'Native binary copy')
    def stop_burst(self):
        if self.burst_process is not None:
            if self.burst_process.stdin and not self.burst_process.stdin.closed:self.burst_process.stdin.close()
            self.burst_process.wait(timeout=12)
            if self.burst_log and not self.burst_log.closed:self.burst_log.close()
            if self.burst_ready:
                pid=self.burst_ready['pid']
                exists=self.run(['docker','exec',self.cid,'test','-d','/proc/'+str(pid)],check=False)
                if exists.returncode==0:
                    now=self.dx(['cat','/proc/'+str(pid)+'/stat']).rsplit(')',1)[1].split()[19]
                    need(now!=self.burst_start_ticks,'Owned native process still alive; preserve resources')
        self.burst_exited=True;self.manifest['NATIVE_CLEANUP_STATUS']='pass'
    def workload(self):
        need(self.channels[0].request('listen')==dict(listening=True),'Root subscription')
        listener=self.channels[0].request('listener-status');self.save('listener-before.json',listener)
        need(listener['netd_alive'] and listener['deaths']==0,'Listener unavailable')
        self.flow('baseline-a-send','a','send',1,1,None)
        base=self.policy('baseline-poll','poll');need(base['policies']==[] and base['recorded_bytes']>0,'Initial policy/usage')
        self.policy_limit=base['recorded_bytes']+2556;self.policy_touched=True;self.manifest['POLICY_STATUS']='fail'
        installed=self.policy('install-policy','set',self.policy_limit);samples=[]
        def ready():
            s=self.snapshot('await-policy-'+str(len(samples)));samples.append(s);q=s['post']['quota']
            return q['present'] and q['limit']==q['remaining']==2556
        try:self.wait(ready,10,'Finite framework allowance')
        finally:self.save('policy-install-samples.json',samples)
        self.dx(['timeout','15','dumpsys','network_management'],'initial-management.log')
        self.capture_policy('installed-netpolicy.xml');self.manifest.update(POLICY_STATUS='pass',USAGE_STATUS='pass',CONTINUITY_STATUS='fail')
        path=self.out/'burst.log';self.burst_log=path.open('xb')
        command=['docker','exec','-i','--user','1001:1001',self.cid,self.android_dir+'/burst',self.nonce,self.fixture.address]
        self.save('burst-command.json',command)
        self.burst_process=subprocess.Popen(command,stdin=subprocess.PIPE,stdout=self.burst_log,stderr=subprocess.STDOUT)
        self.wait(lambda:path.stat().st_size>0 or self.burst_process.poll() is not None,10,'Native start barrier')
        need(self.burst_process.poll() is None,'Native startup failed')
        rows=[json.loads(v) for v in path.read_text().splitlines()];need(len(rows)==1 and rows[0]['event']=='ready','Native readiness')
        self.burst_ready=rows[0];r=self.burst_ready
        need(r['uid']==r['gid']==1001 and int(r['cap_eff'],16)==0 and r['nonce']==self.nonce
             and r['remote']==self.fixture.address and r['local'].rsplit(':',1)[0]==self.container_ip,'Native scope')
        self.dx(['cat','/proc/'+str(r['pid'])+'/status'],'burst-status.log')
        self.burst_start_ticks=self.dx(['cat','/proc/'+str(r['pid'])+'/stat'],'burst-stat.log').rsplit(')',1)[1].split()[19]
        self.fixture.register(1001,r['local']);self.save('burst-ready.json',r)
        before=self.snapshot('continuous-before');self.burst_process.stdin.write((self.nonce+'\n').encode());self.burst_process.stdin.flush()
        during=[];deadline=time.monotonic()+15
        while self.burst_process.poll() is None:
            need(time.monotonic()<deadline,'Bounded native stream deadline')
            during.append(self.snapshot('continuous-during-'+str(len(during))));time.sleep(.01)
        need(self.burst_process.returncode==0,'Native stream failed');self.stop_burst()
        self.save('continuous-samples.json',during);time.sleep(.5);settled=[]
        def automatic():
            snapshot=self.snapshot('continuous-settle-'+str(len(settled)));settled.append(snapshot)
            value=snapshot['post']['quota']
            return value['present'] and value['generation']>before['post']['quota']['generation'] \
                and value['limit']==value['remaining']==1
        try:self.wait(automatic,5,'Automatic post-stream one-byte cap')
        finally:self.save('continuous-settle-samples.json',settled)
        after=self.snapshot('continuous-after')
        rows=[json.loads(v) for v in path.read_text().splitlines()];need(len(rows)==2 and rows[-1]['event']=='finished','Native completion')
        callbacks=self.channels[0].request('callbacks');live=self.channels[0].request('listener-status')
        self.save('callback-ledger.json',callbacks);self.save('listener-after.json',live)
        final=self.policy('final-inspect','inspect');self.dx(['timeout','15','dumpsys','netd'],'continuous-netd.log')
        self.dx(['timeout','15','dumpsys','network_management'],'continuous-management.log')
        self.capture_policy('final-netpolicy.xml')
        case=dict(nonce=self.nonce,absolute_limit=self.policy_limit,baseline=base,installed=installed,final_policy=final,
            before=before,after=after,during=during,ready=r,finished=rows[-1],callbacks=callbacks,
            listener_before=listener,listener_after=live)
        self.save('continuity-case.json',case);result=assess(case,self.fixture.records());self.save('continuity-assessment.json',result)
        self.save('plan.json',self.plan);self.manifest.update(RECALCULATION_STATUS='pass',AUTOMATIC_STATS_STATUS='pass')
        self.manifest.update(CONTINUITY_STATUS='pass',WORKLOAD_STATUS='pass')
    def replay_packets(self):
        load=lambda name:json.loads((self.out/name).read_text())
        scope=load('scope.json');replay_for_scope(self.out,scope)
        rows=[json.loads(v) for v in (self.out/'fixture.jsonl').read_text().splitlines()]
        base=load('baseline-a-send.json');base['fixture']=rows
        need(base['ready']==scope['workers']['a']['ready'],'Baseline worker changed')
        ready=base['ready'];need(ready['gid']==ready['uid'] and int(ready['cap_eff'],16)==0
            and ready['importance']==300 and 10000<=ready['uid']<20000,'Baseline privilege/state')
        baseline=assess_flow(base)
        need(load('plan.json')==[dict(label='baseline-a-send',role='a',**baseline)],'Baseline plan changed')
        need(all(v['uid']==1001 or (v['uid']==base['uid'] and v['step']==base['step']) for v in rows),
             'Unplanned fixture receipt')
        case=load('continuity-case.json');need(case['nonce']==scope['nonce'],'Case nonce changed')
        need(case['ready']==load('burst-ready.json') and case['callbacks']==load('callback-ledger.json')
             and case['listener_before']==load('listener-before.json') and case['listener_after']==load('listener-after.json')
             and case['baseline']==load('baseline-poll.json') and case['installed']==load('install-policy.json')
             and case['final_policy']==load('final-inspect.json'),'Case differs from raw observations')
        records=[json.loads(v) for v in (self.out/'burst.log').read_text().splitlines()]
        need(len(records)==2 and case['ready']==records[0] and case['finished']==records[-1],'Native ledger changed')
        original,accounting=load('initial-quota.json'),load('initial-accounting.json')
        for snapshot in [case['before'],*case['during'],case['after']]:
            for side,source in [('pre',accounting),('post',original)]:
                need(all(snapshot[side][k]==source[k] for k in ('ifindex','map_id','production_links'))
                     and snapshot[side]['query']==scope['chains'],'Original packet source changed')
            need(all(snapshot['post']['quota'][k]==original['quota'][k] for k in ('map_id','drops_map_id'))
                 and snapshot['post']['quota_admitted']['map_id']==original['quota_admitted']['map_id'],
                 'Original quota source changed')
        for key,label in [('before','continuous-before'),('after','continuous-after')]:
            raw={}
            for side in ('pre','post'):
                paths=list((self.out/('observer-'+side)).glob('s*-'+label+'.json'))
                need(len(paths)==1,'Missing or duplicate raw boundary');raw[side]=json.loads(paths[0].read_text())
            need(case[key]==raw,'Case boundary differs from raw observer output')
        return assess(case,rows)
    def finish(self):
        self.attempt('native stream completion',self.stop_burst)
        super().finish()
    def before_owned_cleanup(self):
        need(self.burst_exited,'Native helper not confirmed stopped; preserve resources')

if __name__=='__main__':sys.exit(main(ContinuityTrial))
