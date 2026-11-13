"""Validate concurrent associated, hard and global receipts without relaxing packet gates."""
from assess import need
from assess_policy_continuity import assess as assess_packets


def target(ledger,nonce):
    rows=ledger['callbacks'];previous=0
    for index,row in enumerate(rows,1):
        need(row['sequence']==index and row['nonce']==nonce and row['caller_uid']==row['caller_pid']==0
             and row['interface']=='eth0' and row['name'] in ('eth0','eth0Alert','globalAlert')
             and previous<=row['time_ns']<=ledger['sampled_ns'],'Actual callback identity/order')
        previous=row['time_ns']
    return [row for row in rows if row['name']=='eth0Alert']


def associated(case):
    event=case['associated'];first=event['arm'];mid=event['rearm'];quiet=event['quiet']
    need(first['before_state']==dict(generation=0,bytes=0,armed=False,committed=0,error=0),'Original associated state')
    need(first['after_state']==dict(generation=1,bytes=1228,armed=True,committed=0,error=0),'First registration')
    for window in (first,mid):
        receipt=window['receipt']
        need(receipt['nonce']==case['nonce'] and receipt['uid']==0
             and receipt['pid']==case['listener_before']['pid'] and receipt['operation']=='set-alert'
             and receipt['bytes']==1228 and receipt['error']==0 and not receipt['denied'],'Associated control identity/acknowledgement')
    for side in ('pre','post'):
        for key in ('ifindex','map_id','production_links','query','counters','observed'):
            need(first['before'][side][key]==first['after'][side][key],'Traffic/source during initial registration')
    initial=case['before']['post']['quota_admitted'];baseline=initial['bytes']
    need(first['before']['post']['quota_admitted']==first['after']['post']['quota_admitted']==initial,
         'Associated baseline changed before the stream')
    need(mid['before_state']==dict(generation=1,bytes=1228,armed=False,committed=1,error=0)
         and mid['after_state']==dict(generation=2,bytes=1228,armed=True,committed=1,error=0),
         'Associated replacement lost the committed first window')
    for sample in (mid['before'],mid['after'],quiet['before'],quiet['after']):
        for side in ('pre','post'):
            need(all(sample[side][key]==case['before'][side][key]
                     for key in ('ifindex','map_id','production_links','query')),'Associated packet source changed')
        need(sample['post']['quota_admitted']==dict(initial,bytes=baseline+2456),'Replacement baseline includes wrong admitted traffic')
        q=sample['post']['quota']
        need(q['present'] and 0<=q['remaining']<=q['limit']<=2556 and q['invalid']==q['contention']==0,
             'Quota lost, regranted or faulted around associated replacement')
    done=case['finished'];ledger=case['callbacks'];rows=target(ledger,case['nonce'])
    need(len(rows)==1,'Missing/duplicate associated receipt')
    need(done['start_ns']<=rows[0]['time_ns']<=mid['start_ns']<mid['end_ns']<done['end_ns']
         and any(t>mid['end_ns'] for t in done['release_ns']),'Associated replacement did not overlap later attempts')
    observed=mid['before']['pre']['observed'][1]['skbs']-case['before']['pre']['observed'][1]['skbs']
    need(2<=observed<=sum(t<=mid['start_ns'] for t in done['release_ns'])<1536,
         'Replacement observation does not belong to a live packet prefix')
    for name in ('eth0','globalAlert'):
        need(any(row['name']==name and done['start_ns']<=row['time_ns']<=done['end_ns'] for row in ledger['callbacks']),
             'Missing concurrent real '+name+' receipt')
    need(quiet['end_ns']-quiet['start_ns']>=1_000_000_000,'Short quiet observation')
    need(done['end_ns']<=quiet['start_ns']<quiet['end_ns']<=ledger['sampled_ns'],
         'Quiet observation does not follow the complete stream')
    need(quiet['before_state']==quiet['after_state']==mid['after_state'],'Denied attempts fired the replacement alert')
    for side in ('pre','post'):
        for key in ('ifindex','map_id','production_links','query','counters','observed'):
            need(quiet['before'][side][key]==quiet['after'][side][key],'Traffic/source changed during quiet observation')
    need(len(target(quiet['callbacks_before'],case['nonce']))==len(target(quiet['callbacks_after'],case['nonce']))==1,
         'Late duplicate/replacement receipt')
    return dict(status='pass',associated_receipts=1,rearmed_generation=2,admitted_bytes=2456,
        hard_receipts=sum(r['name']=='eth0' for r in ledger['callbacks']),
        global_receipts=sum(r['name']=='globalAlert' for r in ledger['callbacks']),
        later_attempts=sum(t>mid['end_ns'] for t in done['release_ns']),
        scope='One associated crossing, live replacement and no false crossing from later denied attempts alongside real hard/global events')



def assess(case,receipts):
    packets=assess_packets(case,receipts,expected_associated=1)
    return dict(packets=packets,associated=associated(case))
