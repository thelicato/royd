"""Saved assessment of real Ethernet policy usage and remaining-budget replay."""
IP_BYTES=1228
MAXIMUM=(1<<63)-1


def need(value, message):
    if not value:
        raise ValueError(message)


def assess(case):
    base, installed, polled = (case[k] for k in ('baseline','installed','polled'))
    for r, op in ((base,'poll'),(installed,'set'),(polled,'poll')):
        need(r['nonce']==case['nonce'] and r['uid']==0 and r['pid']>1
             and r['operation']==op and r['sampled_ns']>0, 'Wrong policy probe identity')
    need(base['sampled_ns']<installed['sampled_ns']<polled['sampled_ns'], 'Policy probe order')
    need(base['cycle_start_ms']==installed['cycle_start_ms']==polled['cycle_start_ms']
         and base['cycle_end_ms']==installed['cycle_end_ms']==polled['cycle_end_ms']
         and base['cycle_start_ms']<base['cycle_end_ms'], 'Usage cycle changed')
    need(base['policies']==[] and installed['policies']==polled['policies']
         and len(installed['policies'])==1, 'Policy ownership changed')
    policy=installed['policies'][0]
    need(policy['match_rule']==5 and policy['meteredness']==-1 and policy['limit']==case['absolute_limit']
         and policy['warning']==policy['last_limit_snooze']==policy['last_warning_snooze']==policy['last_rapid_snooze']==-1
         and policy['metered'] and not policy['inferred'], 'Unexpected Ethernet policy')
    need(base['recorded_bytes']>0 and installed['recorded_bytes']==base['recorded_bytes']
         and case['absolute_limit']==base['recorded_bytes']+2*IP_BYTES+100<MAXIMUM,
         'Cycle usage was not deducted from the absolute policy limit')
    need(polled['recorded_bytes']==base['recorded_bytes']+2*IP_BYTES, 'Recorded admitted usage differs')
    before, consumed, after = (case[k] for k in ('before','consumed','after'))
    for v in (before,consumed,after):
        need(v['pre']['counters']==v['post']['counters'], 'Non-quiescent policy snapshot')
        q=v['post']['quota']
        need(q['present'] and q['generation']>0 and q['invalid']==q['contention']==0,
             'Unhealthy finite backend')
        for key in ('ifindex','map_id','production_links','query'):
            need(v['post'][key]==before['post'][key], 'Backend source changed')
        for key in ('map_id','drops_map_id'):
            need(q[key]==before['post']['quota'][key]>0, 'Quota source changed')
        need(v['post']['quota_admitted']['map_id']==before['post']['quota_admitted']['map_id']>0,
             'Admitted counter source changed')
    a,b,c=(v['post']['quota'] for v in (before,consumed,after))
    need(a['limit']==a['remaining']==2*IP_BYTES+100, 'Initial finite allowance ignores recorded usage')
    need(b['generation']==a['generation'] and b['limit']==a['limit'] and b['remaining']==100,
         'Unexpected policy change during the two packet windows')
    need(c['generation']>b['generation'] and c['limit']==c['remaining']==100,
         'Framework replay restored already consumed allowance')
    expected=[1,IP_BYTES,1,IP_BYTES]
    need([y-x for x,y in zip(before['post']['counters'],consumed['post']['counters'])]==expected,
         'Unexpected whole-window IP traffic')
    need(consumed['post']['counters']==after['post']['counters'], 'Poll control generated unrelated IP')
    u=[v['post']['quota_admitted']['bytes'] for v in (before,consumed,after)]
    need(0<=u[0]<u[1]==u[2]<1<<64 and u[1]-u[0]==2*IP_BYTES, 'Admitted usage mismatch')
    return dict(status='pass',scope='Framework-owned Ethernet usage deduction and explicit-poll recalculation; exhaustion/restart feedback separate',
                baseline_recorded_bytes=base['recorded_bytes'],initial_remaining=a['remaining'],
                admitted_bytes=2*IP_BYTES,recalculated_remaining=c['remaining'])
