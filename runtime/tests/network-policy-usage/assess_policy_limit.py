"""Hard-limit receipts plus exact packet denial and automatic policy recalculation."""
from assess_policy_usage import need, IP_BYTES, MAXIMUM
from assess import assess_packets

EVENT_LABELS=('crossing-b-send','blocked-system-receive','blocked-a-send')


def event_flow(item):
    result=assess_packets(item)
    a,b=(item[k]['post']['quota'] for k in ('before','after'))
    need(item['label'] in EVENT_LABELS and item['count']==1 and item['passed']==0
         and item['remaining']==0,'Not an owned exhaustion/denial window')
    for key in ('present','map_id','drops_map_id','invalid','contention'):
        need(a[key]==b[key],'Quota source/fault changed')
    need(a['present'] and a['map_id']>0 and a['drops_map_id']>0
         and a['invalid']==a['contention']==0 and a['generation']>0,'Unhealthy quota')
    need(0<=a['remaining']<IP_BYTES and a['remaining']<=a['limit']<MAXIMUM,'Packet could fit')
    if item['label']=='crossing-b-send':
        need(a['limit']==2*IP_BYTES+100 and a['remaining']==100,'Wrong crossing boundary')
    else:
        need(a['limit']==1,'Post-limit allowance differs from the derived minimum')
    if b['generation']==a['generation']:
        need(b['limit']==a['limit'] and b['remaining']==0,'Same-generation drop did not exhaust')
    else:
        # A real event lets the framework replace the exhausted generation.
        # Never accept MAX replay, the absolute limit or a fresh finite grant.
        need(b['generation']>a['generation'] and b['limit']==1 and b['remaining'] in (0,1),
             'Unexpected quota replacement/regrant during notification')
    before,after=(item[k]['post']['quota_admitted'] for k in ('before','after'))
    need(before['map_id']==after['map_id']>0 and before['bytes']==after['bytes'],
         'Denied traffic advanced admitted use')
    return dict(**result,remaining=b['remaining'],generation=b['generation'],notification_window=True)


def assess(case):
    base,installed,first,final=(case[k] for k in ('baseline','installed','first_inspect','final_inspect'))
    need(case['absolute_limit']==base['recorded_bytes']+2*IP_BYTES+100<MAXIMUM
         and base['recorded_bytes']>0 and base['policies']==[],'Initial policy/usage')
    for sample,op in ((base,'poll'),(installed,'set'),(first,'inspect'),(final,'inspect')):
        need(sample['operation']==op and sample['uid']==0 and sample['pid']>1
             and sample['nonce']==case['nonce'],'Probe operation/identity differs')
        need(sample['cycle_start_ms']==base['cycle_start_ms']
             and sample['cycle_end_ms']==base['cycle_end_ms'],'Recorded cycle changed')
    need(base['sampled_ns']<installed['sampled_ns']<first['sampled_ns']<final['sampled_ns'],'Probe order')
    need(installed['recorded_bytes']==base['recorded_bytes'],'Usage changed while installing policy')
    need(installed['policies']==first['policies']==final['policies']
         and len(installed['policies'])==1,'Policy ownership changed')
    p=installed['policies'][0]
    need(p['match_rule']==5 and p['meteredness']==-1 and p['limit']==case['absolute_limit']
         and p['warning']==p['last_limit_snooze']==p['last_warning_snooze']==p['last_rapid_snooze']==-1
         and p['metered'] and not p['inferred'],'Unexpected policy')
    need(first['recorded_bytes']==base['recorded_bytes']+3*IP_BYTES
         and final['recorded_bytes']==base['recorded_bytes']+5*IP_BYTES,'Automatic recorded attempts differ')
    initial,auto,done=(case[k] for k in ('initial','first_auto','final_auto'))
    q0,q1,q2=(x['post']['quota'] for x in (initial,auto,done))
    need(q0['limit']==q0['remaining']==2*IP_BYTES+100,'Initial allowance ignores recorded use')
    need(q0['generation']<q1['generation']<q2['generation'] and q1['limit']==q1['remaining']==1
         and q2['limit']==q2['remaining']==1,'Missing automatic recalculation or quota regrant')
    for snapshot in (initial,auto,done):
        need(snapshot['pre']['counters']==snapshot['post']['counters'],'Non-quiescent policy snapshot')
        v=snapshot['post'];q=v['quota'];start=initial['post']
        need(q['present'] and q['invalid']==q['contention']==0,'Quota source fault')
        for key in ('ifindex','map_id','production_links','query'):
            need(v[key]==start[key],'Accounting/attachment source changed')
        for key in ('map_id','drops_map_id'):
            need(q[key]==start['quota'][key]>0,'Quota map changed')
        need(v['quota_admitted']['map_id']==start['quota_admitted']['map_id']>0,'Admitted source changed')
    for sample,packets in ((auto,[1,IP_BYTES,2,2*IP_BYTES]),(done,[2,2*IP_BYTES,3,3*IP_BYTES])):
        need([y-x for x,y in zip(initial['post']['counters'],sample['post']['counters'])]==packets,
             'Unrelated or missing whole-window IP traffic')
        need(sample['post']['quota_admitted']['bytes']-initial['post']['quota_admitted']['bytes']==2*IP_BYTES,
             'Admitted use differs from the two fitting packets')
    callbacks=case['callbacks']['callbacks'];last=0
    for number,receipt in enumerate(callbacks,1):
        need(receipt['sequence']==number and receipt['nonce']==case['nonce']
             and receipt['caller_uid']==receipt['caller_pid']==0 and receipt['interface']=='eth0'
             and receipt['name'] in ('eth0','eth0Alert','globalAlert')
             and last<=receipt['time_ns']<=final['sampled_ns'],'Invalid real callback ledger')
        last=receipt['time_ns']
    hard=[r for r in callbacks if r['name']=='eth0']
    need(2<=len(hard)<=3,'Missing repeated real hard-limit receipts')
    need(hard[0]['time_ns']>=case['crossing_release_ns'],'Hard notification preceded the crossing')
    before,after=case['listener_before'],case['listener_after']
    need(before['netd_alive'] and after['netd_alive'] and before['pid']==after['pid']>1
         and before['uid']==after['uid']==0 and before['deaths']==after['deaths']==0,'Listener lifetime changed')
    return dict(status='pass',hard_limit_receipts=len(hard),attempted_finite_packets=5,
                admitted_finite_packets=2,denied_finite_packets=3,automatic_remaining=1,
                scope='Framework-owned hard-limit feedback and subsequent denial, not restart/concurrent-alert acceptance')
