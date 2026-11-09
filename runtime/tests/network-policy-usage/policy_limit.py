"""Real hard-quota receipts with framework-owned policy and automatic stats."""
import json,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(ROOT/'runtime/tests/network-quota'))
from policy_usage import PolicyUsageTrial
from run import main
from assess import need,assess_flow
from fixture import IP_BYTES
from preparation import replay_for_scope
from assess_policy_limit import assess,event_flow,EVENT_LABELS


class PolicyLimitTrial(PolicyUsageTrial):
    result_name='Framework hard-limit notification'
    extra_required=PolicyUsageTrial.extra_required+('HARD_LIMIT_STATUS','AUTOMATIC_STATS_STATUS')

    def __init__(self):
        super().__init__()
        self.manifest.update(ROYD_POLICY_LIMIT_EVIDENCE_FORMAT=1,HARD_LIMIT_STATUS='not-tested',
                             AUTOMATIC_STATS_STATUS='not-tested')

    def assess_item(self,item):
        return event_flow(item) if item['label'] in EVENT_LABELS else assess_flow(item)

    def automatic(self,label,minimum,used,old_generation):
        samples=[]
        def converged():
            callbacks=self.channels[0].request('callbacks')
            query=self.policy(label+'-inspect-'+str(len(samples)),'inspect')
            snapshot=self.snapshot(label+'-'+str(len(samples)))
            samples.append(dict(callbacks=callbacks,query=query,packets=snapshot))
            q=snapshot['post']['quota']
            need(query['policies']==self.installed_policy['policies'],'Framework policy changed')
            if q['present'] and q['generation']>old_generation:
                need(q['limit']==1 and q['remaining'] in (0,1),'Unexpected allowance regrant')
            count=sum(x['name']=='eth0' and x['interface']=='eth0' for x in callbacks['callbacks'])
            return count>=minimum and query['recorded_bytes']==used and q['present'] \
                and q['limit']==q['remaining']==1 and q['generation']>old_generation
        try:
            self.wait(converged,5,'Real hard-limit receipt, automatic stats and derived one-byte allowance')
        finally:
            self.save(label+'-samples.json',samples)
        return samples[-1]

    def workload(self):
        self.manifest['POLICY_STATUS']='fail'
        need(self.channels[0].request('listen')==dict(listening=True),'Root listener acknowledgement')
        listener=self.channels[0].request('listener-status');self.save('listener-before.json',listener)
        need(listener['netd_alive'] and listener['uid']==0 and listener['deaths']==0,'Listener unavailable')
        self.flow('baseline-a-send','a','send',1,1,None)
        baseline=self.policy('baseline-poll','poll')
        need(baseline['policies']==[] and baseline['recorded_bytes']>0,'Initial policy/usage')
        self.policy_limit=baseline['recorded_bytes']+2*IP_BYTES+100;self.policy_touched=True
        self.installed_policy=self.policy('install-policy','set',self.policy_limit)
        samples=[]
        def ready():
            snapshot=self.snapshot('await-policy-'+str(len(samples)));samples.append(snapshot)
            q=snapshot['post']['quota']
            return q['present'] and q['limit']==q['remaining']==2*IP_BYTES+100
        self.wait(ready,10,'Finite framework allowance')
        self.save('policy-install-samples.json',samples);initial=samples[-1]
        self.expected_quota=initial['post']['quota'];self.capture_policy('installed-netpolicy.xml')
        self.manifest.update(POLICY_STATUS='pass',USAGE_STATUS='fail',HARD_LIMIT_STATUS='fail',
                             AUTOMATIC_STATS_STATUS='fail',RECALCULATION_STATUS='fail')
        self.flow('finite-a-send','a','send',1,1,IP_BYTES+100)
        self.flow('finite-system-receive','system','receive',1,1,100)
        # A real event lets the owner replace an exhausted generation. Only
        # the derived one-byte cap is accepted; packet/noise checks stay intact.
        self.expected_quota=None
        self.flow('crossing-b-send','b','send',1,0,0)
        cross=json.loads((self.out/'crossing-b-send.json').read_text())
        first=self.automatic('first-auto',1,baseline['recorded_bytes']+3*IP_BYTES,
                             initial['post']['quota']['generation'])
        self.capture_policy('first-auto-netpolicy.xml')
        self.flow('blocked-system-receive','system','receive',1,0,0)
        self.flow('blocked-a-send','a','send',1,0,0)
        final=self.automatic('final-auto',2,baseline['recorded_bytes']+5*IP_BYTES,
                             first['packets']['post']['quota']['generation'])
        callbacks=self.channels[0].request('callbacks')
        live=self.channels[0].request('listener-status');self.save('listener-after.json',live)
        final_query=self.policy('final-inspect','inspect')
        self.capture_policy('final-auto-netpolicy.xml')
        case=dict(nonce=self.nonce,absolute_limit=self.policy_limit,baseline=baseline,
            installed=self.installed_policy,initial=initial,first_inspect=first['query'],
            final_inspect=final_query,first_auto=first['packets'],final_auto=final['packets'],
            callbacks=callbacks,listener_before=listener,listener_after=live,
            crossing_release_ns=cross['app']['released_ns'])
        self.save('hard-limit-case.json',case);self.save('hard-limit-assessment.json',assess(case))
        self.save('plan.json',self.plan)
        self.manifest.update(USAGE_STATUS='pass',HARD_LIMIT_STATUS='pass',AUTOMATIC_STATS_STATUS='pass',
                             RECALCULATION_STATUS='pass',WORKLOAD_STATUS='pass')

    def replay_packets(self):
        scope=json.loads((self.out/'scope.json').read_text());replay_for_scope(self.out,scope)
        plans=json.loads((self.out/'plan.json').read_text())
        need([x['label'] for x in plans]==['baseline-a-send','finite-a-send','finite-system-receive',
             'crossing-b-send','blocked-system-receive','blocked-a-send'],'Incomplete/reordered hard-limit plan')
        roles=['a','a','system','b','system','a']
        fixture=[json.loads(line) for line in (self.out/'fixture.jsonl').read_text().splitlines()]
        allowed={(x['uid'],x['step']) for x in plans}
        need(all((x['uid'],x['step']) in allowed for x in fixture),'Unplanned fixture receipt')
        original=json.loads((self.out/'initial-quota.json').read_text())
        accounting=json.loads((self.out/'initial-accounting.json').read_text())
        need(len({scope['workers'][r]['ready']['uid'] for r in ('a','b','system')})==3,
             'Workers are not distinct')
        for row,role in zip(plans,roles):
            item=json.loads((self.out/(row['label']+'.json')).read_text());item['fixture']=fixture
            need(item['label']==row['label'] and item['op']==('receive' if role=='system' else 'send')
                 and item['count']==1 and item['passed']==(0 if row['label'] in EVENT_LABELS else 1),
                 'Saved packet plan changed')
            need(item['ready']==scope['workers'][role]['ready'],'Saved worker changed')
            ready=item['ready']
            need(ready['uid']==ready['gid'] and int(ready['cap_eff'],16)==0,'Worker privilege')
            need((ready['uid']==1000 and ready['importance']==-1 and ready['cgroup'].strip()=='0::/royd/init')
                 if role=='system' else (10000<=ready['uid']<20000 and ready['importance']==300
                                        and '/uid_'+str(ready['uid'])+'/' in ready['cgroup']), 'Worker scope')
            for snapshot in (item['before'],item['after']):
                for side,source in (('pre',accounting),('post',original)):
                    value=snapshot[side]
                    need(all(value[k]==source[k] for k in ('ifindex','map_id','production_links'))
                         and value['query']==scope['chains'],'Changed original packet source')
                need(all(snapshot['post']['quota'][k]==original['quota'][k]
                         for k in ('map_id','drops_map_id'))
                     and snapshot['post']['quota_admitted']['map_id']==original['quota_admitted']['map_id'],
                     'Changed original quota source')
            result=self.assess_item(item)
            need(row==dict(label=row['label'],role=role,**result),'Saved phase assessment differs')
        case=json.loads((self.out/'hard-limit-case.json').read_text())
        load=lambda name:json.loads((self.out/name).read_text())
        need(case['baseline']==load('baseline-poll.json')
             and case['installed']==load('install-policy.json')
             and case['initial']==load('policy-install-samples.json')[-1]
             and case['first_inspect']==load('first-auto-samples.json')[-1]['query']
             and case['first_auto']==load('first-auto-samples.json')[-1]['packets']
             and case['final_inspect']==load('final-inspect.json')
             and case['final_auto']==load('final-auto-samples.json')[-1]['packets']
             and case['crossing_release_ns']==load('crossing-b-send.json')['app']['released_ns']
             and case['listener_before']==load('listener-before.json')
             and case['listener_after']==load('listener-after.json'),'Case differs from raw saved observations')
        need(case['nonce']==scope['nonce'] and case['initial']['post']['quota']['map_id']==original['quota']['map_id']
             and case['initial']['post']['quota_admitted']['map_id']==original['quota_admitted']['map_id'],
             'Case changed owned source')
        return assess(case)


if __name__=='__main__':sys.exit(main(PolicyLimitTrial))
