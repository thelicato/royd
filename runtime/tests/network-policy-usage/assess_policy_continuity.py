"""Exact continuous-packet acceptance under one framework-owned finite policy."""
import hashlib
from fixture import packet,IP_BYTES
from assess import need

def assess(case,receipts):
    a,b=case['before'],case['after'];count=1536
    for side in ('pre','post'):
        x,y=a[side],b[side]
        need(all(x[k]==y[k] for k in ('ifindex','map_id','production_links','query')),'Packet source changed')
        need([v-u for u,v in zip(x['counters'],y['counters'])]==[0,0,count,count*IP_BYTES],
             'Missing or unrelated IP attempts')
        need(x['observed'][0]==y['observed'][0],'Unexpected ingress')
        need(all(x['observed'][1][k]==y['observed'][1][k] for k in ('other_ip_skbs','errors','gso_skbs')),
             'Unrelated/malformed/segmented traffic')
    need(a['pre']['counters']==a['post']['counters'] and b['pre']['counters']==b['post']['counters'],
         'Non-quiescent boundary')
    admitted=b['post']['observed'][1]['skbs']-a['post']['observed'][1]['skbs']
    for side,expected in [('pre',count),('post',admitted)]:
        x,y=a[side]['observed'][1],b[side]['observed'][1]
        need(y['skbs']-x['skbs']==y['segments']-x['segments']==expected
             and y['raw_bytes']-x['raw_bytes']==expected*(IP_BYTES+14),'Packet multiplicity/length')
    q=a['post']['quota'];need(q['present'] and q['limit']==q['remaining']==2556
        and q['generation']>0 and q['map_id']>0 and q['drops_map_id']>0,'Starting allowance')
    for value in (a['post'],b['post']):
        need(value['quota']['map_id']==q['map_id'] and value['quota']['drops_map_id']==q['drops_map_id']
             and value['quota']['invalid']==value['quota']['contention']==0,'Quota source/fault')
        need(value['quota_admitted']['map_id']==a['post']['quota_admitted']['map_id']>0,'Admitted source')
    charged=b['post']['quota_admitted']['bytes']-a['post']['quota_admitted']['bytes']
    ready,done=case['ready'],case['finished'];need(ready['uid']==ready['gid']==1001 and ready['pid']>1
        and int(ready['cap_eff'],16)==0 and ready['event']=='ready' and done['event']=='finished','Native privilege/identity')
    need(all(ready[k]==done[k] for k in ('uid','gid','pid','nonce','local','remote')),'Native identity changed')
    need(done['attempted']==done['successful']+done['enobufs']==count and len(done['release_ns'])==count
         and done['start_ns']<=min(done['release_ns'])<=max(done['release_ns'])<=done['end_ns'], 'Native result/timing')
    rows=[v for v in receipts if v['uid']==1001]
    need(len(rows)==admitted and len({(v['step'],v['sequence']) for v in rows})==len(rows),'Fixture admission/multiplicity')
    for row in rows:
        need(row['event']=='receive' and row['kind']==1 and row['count']==64 and 1<=row['step']<=24
             and row['peer']==ready['local'] and row['sha256']==hashlib.sha256(packet(
                 bytes.fromhex(ready['nonce']),row['step'],1001,row['sequence'],64,1)).hexdigest(),'Fixture identity')
    need(case['baseline']['policies']==[] and case['installed']['policies']==case['final_policy']['policies']
         and case['absolute_limit']-case['baseline']['recorded_bytes']==2556,'Policy ownership')
    for sample,operation in ((case['baseline'],'poll'),(case['installed'],'set'),(case['final_policy'],'inspect')):
        need(sample['operation']==operation and sample['uid']==0 and sample['pid']>1
             and sample['nonce']==case['nonce'],'Policy probe identity/operation')
        need(sample['cycle_start_ms']==case['baseline']['cycle_start_ms']
             and sample['cycle_end_ms']==case['baseline']['cycle_end_ms'],'Policy cycle changed')
    need(case['baseline']['recorded_bytes']>0 and case['installed']['recorded_bytes']==case['baseline']['recorded_bytes'],
         'Initial recorded usage changed')
    need(case['baseline']['sampled_ns']<case['installed']['sampled_ns']<case['final_policy']['sampled_ns'],
         'Policy observation order')
    policy=case['installed']['policies']
    need(len(policy)==1 and policy[0]['match_rule']==5 and policy[0]['meteredness']==-1
         and policy[0]['limit']==case['absolute_limit'] and policy[0]['metered'] and not policy[0]['inferred']
         and all(policy[0][k]==-1 for k in ('warning','last_limit_snooze','last_warning_snooze','last_rapid_snooze')),
         'Unexpected framework policy')
    need(case['final_policy']['recorded_bytes']>=case['absolute_limit'],'Automatic recorded usage did not reach the limit')
    previous=0
    ledger=case['callbacks']
    need(0<len(ledger['callbacks'])<=32 and ledger['sampled_ns']<=case['final_policy']['sampled_ns'],'Callback ledger bounds')
    for number,row in enumerate(ledger['callbacks'],1):
        need(row['sequence']==number and row['nonce']==case['nonce'] and row['caller_uid']==row['caller_pid']==0
             and row['interface']=='eth0' and row['name'] in ('eth0','globalAlert')
             and 0<row['time_ns']<=ledger['sampled_ns'] and row['time_ns']>=previous,'Callback identity/order')
        previous=row['time_ns']
    for sample in case['during']+[b]:
        for side in ('pre','post'):
            need(all(sample[side][k]==a[side][k] for k in ('ifindex','map_id','production_links','query')),
                 'Source changed during the stream')
        value=sample['post']['quota']
        need(value['present'] and value['map_id']==q['map_id'] and value['drops_map_id']==q['drops_map_id']
             and value['invalid']==value['contention']==0 and value['generation']>=q['generation']
             and 0<=value['remaining']<=value['limit']<=2556,'Absent or regranted quota during an owned policy')
    need(b['post']['quota']['generation']>q['generation']
         and b['post']['quota']['limit']==b['post']['quota']['remaining']==1,'Missing final automatic one-byte cap')
    for direction in (0,1):
        chain=a['pre']['query'][direction]
        need(chain==a['post']['query'][direction] and len(chain)==len(set(chain))==4
             and chain[0]==a['pre']['production_links'][direction]
             and chain[2]==a['post']['production_links'][direction],'Observer order')
    need(done['release_ns']==sorted(done['release_ns']),'Native release order')
    need(admitted==2 and charged==2*IP_BYTES,'Finite quota admission/charge differs from its two fitting packets')
    hard=[r for r in case['callbacks']['callbacks'] if r['name']=='eth0']
    need(hard and all(r['interface']=='eth0' and r['caller_uid']==r['caller_pid']==0
         and r['nonce']==ready['nonce'] for r in hard),'Real hard-limit receipts required')
    for key in ('pid','uid','netd_alive','deaths','death_ns'):
        need(case['listener_before'][key]==case['listener_after'][key],'Listener lifetime changed')
    need(case['listener_after']['netd_alive'] and case['listener_after']['deaths']==0,'Listener unavailable')
    return dict(status='pass',attempted=count,admitted=admitted,
        denied=count-admitted,initial_allowance=2556,admitted_counter_bytes=charged,
        uncharged_admissions=admitted-charged//IP_BYTES,hard_receipts=len(hard),
        global_receipts=sum(r['name']=='globalAlert' for r in ledger['callbacks']),
        scope='One continuous controlled IPv4 native stream under a framework-owned quota, not general concurrency acceptance')
