"""Owned ordinary/native packets under a stock finite Ethernet network policy."""
import hashlib, json, sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(ROOT/'runtime/tests/network-quota'))
from run import Trial, MAXIMUM, SCRIPTS, main
from assess import need, assess_flow
from fixture import IP_BYTES
from assess_policy_usage import assess


class PolicyUsageTrial(Trial):
    result_name='OCI network-policy usage'
    quota_inspect_mode='inspect-quota-alert'
    quota_observe_mode='observe-quota-alert'
    extra_required=('POLICY_STATUS','USAGE_STATUS','RECALCULATION_STATUS','POLICY_RESTORE_STATUS')

    def __init__(self):
        super().__init__()
        need(self.link is not None,'Policy usage gate requires the controlled IPv4 link')
        self.policy_limit=None;self.policy_touched=False
        self.manifest.update(ROYD_POLICY_USAGE_EVIDENCE_FORMAT=1,POLICY_STATUS='not-tested',
            USAGE_STATUS='not-tested',RECALCULATION_STATUS='not-tested',POLICY_RESTORE_STATUS='not-tested')

    def prepare_container(self):
        super().prepare_container()
        self.run([SCRIPTS/'network-policy-usage-build.sh',self.out/'policy-build'],'policy-build.log',timeout=120)
        self.run(['docker','cp',self.out/'policy-build/dex/classes.dex',self.cid+':'+self.android_dir+'/policy.dex'])
        self.dx(['chmod','644',self.android_dir+'/policy.dex'])

    def policy(self,label,op,*args):
        result=self.run(self.java('org.royd.policyusage.PolicyUsageProbe','policy.dex',
            [self.nonce,op,*[str(x) for x in args]]),label+'.log',timeout=30)
        rows=[json.loads(l) for l in result.stdout.splitlines() if l.startswith('{')]
        need(len(rows)==1,'Policy probe result shape')
        r=rows[0]
        need(r['nonce']==self.nonce and r['operation']==op and r['uid']==0 and r['pid']>1,'Policy probe identity')
        self.save(label+'.json',r)
        return r

    def capture_policy(self,name):
        target=self.out/name
        need(not target.exists() and not target.is_symlink(),'Policy evidence already exists')
        source='/data/system/netpolicy.xml'
        before=self.dx(['sha256sum',source],name+'.source-before.log').split()[0]
        self.run(['docker','cp',self.cid+':'+source,target],name+'.copy.log')
        after=self.dx(['sha256sum',source],name+'.source-after.log').split()[0]
        need(target.is_file() and not target.is_symlink(),'Policy evidence is not a regular file')
        data=target.read_bytes()
        digest=hashlib.sha256(data).hexdigest()
        need(data and digest==before==after,'Policy evidence differs from the live file')
        self.save(name+'.capture.json',dict(source=source,bytes=len(data),sha256=digest))

    def workload(self):
        self.manifest['POLICY_STATUS']='fail'
        self.flow('baseline-a-send','a','send',1,1,None)
        base=self.policy('baseline-poll','poll')
        need(base['policies']==[] and base['recorded_bytes']>0,'Initially empty policies and real usage required')
        self.policy_limit=base['recorded_bytes']+2*IP_BYTES+100
        self.policy_touched=True
        installed=self.policy('install-policy','set',self.policy_limit)
        need(len(installed['policies'])==1 and installed['policies'][0]['limit']==self.policy_limit,
             'Installed policy differs')
        samples=[]
        def ready():
            s=self.snapshot('await-policy-'+str(len(samples)));samples.append(s)
            q=s['post']['quota']
            return q['present'] and q['limit']==q['remaining']==2*IP_BYTES+100
        self.wait(ready,10,'Framework finite allowance after recorded usage')
        self.save('policy-install-samples.json',samples)
        before=samples[-1];self.expected_quota=before['post']['quota']
        self.capture_policy('installed-netpolicy.xml')
        self.manifest.update(POLICY_STATUS='pass',USAGE_STATUS='fail')
        self.flow('finite-a-send','a','send',1,1,IP_BYTES+100)
        self.flow('finite-system-receive','system','receive',1,1,100)
        consumed=self.snapshot('before-explicit-poll')
        self.manifest.update(USAGE_STATUS='pass',RECALCULATION_STATUS='fail')
        polled=self.policy('explicit-poll','poll')
        controls=[]
        def recalculated():
            s=self.snapshot('await-recalculation-'+str(len(controls)));controls.append(s)
            q=s['post']['quota']
            return q['present'] and q['limit']==q['remaining']==100 and q['generation']>consumed['post']['quota']['generation']
        self.wait(recalculated,10,'Framework policy recalculation without allowance inflation')
        self.save('recalculation-samples.json',controls)
        self.capture_policy('recalculated-netpolicy.xml')
        case=dict(nonce=self.nonce,absolute_limit=self.policy_limit,baseline=base,installed=installed,
                  polled=polled,before=before,consumed=consumed,after=controls[-1])
        self.save('policy-usage-case.json',case);self.save('policy-usage-assessment.json',assess(case))
        self.save('plan.json',self.plan)
        self.manifest.update(RECALCULATION_STATUS='pass',WORKLOAD_STATUS='pass')

    def replay_packets(self):
        from preparation import replay_for_scope
        scope=json.loads((self.out/'scope.json').read_text())
        replay_for_scope(self.out,scope)
        plans=json.loads((self.out/'plan.json').read_text())
        need([r['label'] for r in plans]==['baseline-a-send','finite-a-send','finite-system-receive'], 'Incomplete/reordered packet plan')
        fixture=[json.loads(line) for line in (self.out/'fixture.jsonl').read_text().splitlines()]
        identities={(r['uid'],r['step']) for r in plans}
        need(all((r['uid'],r['step']) in identities for r in fixture),'Unplanned final fixture receipt')
        for row in plans:
            role='system' if row['label']=='finite-system-receive' else 'a'
            item=json.loads((self.out/(row['label']+'.json')).read_text())
            need(item['ready']==scope['workers'][role]['ready'],'Changed saved worker identity')
            ready=item['ready']
            need(ready['uid']==ready['gid'] and int(ready['cap_eff'],16)==0
                 and ready['importance']==(-1 if role=='system' else 300),'Wrong worker privilege/state')
            item['fixture']=fixture
            result=assess_flow(item)
            need(row==dict(label=row['label'],role=role,**result), 'Saved packet assessment differs')
        case=json.loads((self.out/'policy-usage-case.json').read_text())
        initial=json.loads((self.out/'initial-quota.json').read_text())
        need(case['nonce']==scope['nonce'] and case['before']['post']['quota']['map_id']==initial['quota']['map_id']
             and case['before']['post']['quota_admitted']['map_id']==initial['quota_admitted']['map_id'],
             'Policy case differs from the original owned source')
        return assess(case)

    def finish(self):
        if self.policy_touched:
            self.finishing=True;self.refresh_enabled=False
            self.manifest['POLICY_RESTORE_STATUS']='fail'
            def restore():
                r=self.policy('remove-owned-policy','remove',self.policy_limit)
                need(r['policies']==[],'Policy removal failed')
                rows=[]
                def unlimited():
                    s=self.snapshot('await-restoration-'+str(len(rows)));rows.append(s)
                    q=s['post']['quota']
                    return q['present'] and q['limit']==MAXIMUM and q['invalid']==q['contention']==0
                self.wait(unlimited,10,'Restored framework default MAX policy')
                self.save('policy-restoration-samples.json',rows)
                self.capture_policy('restored-netpolicy.xml')
                self.manifest['POLICY_RESTORE_STATUS']='pass'
            self.attempt('restore owned framework policy',restore)
        else:self.manifest['POLICY_RESTORE_STATUS']='pass'
        super().finish()

    def before_owned_cleanup(self):
        need(not self.policy_touched or self.manifest['POLICY_RESTORE_STATUS']=='pass',
             'Unrestored policy requires retained resources')


if __name__=='__main__':sys.exit(main(PolicyUsageTrial))
