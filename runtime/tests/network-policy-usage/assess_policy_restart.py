"""Assess finite policy/history preservation and automatic readiness after restart."""
import hashlib,json,re
from fixture import packet


def need(value,message):
    if not value:raise ValueError(message)


def assess_initial(case):
    base,installed,query=(case[k] for k in ('baseline','installed','query'))
    need(re.fullmatch('[0-9a-f]{32}',case['nonce']) is not None,'Missing policy nonce')
    for value,op in ((base,'inspect'),(installed,'set'),(query,'inspect')):
        need(value['nonce']==case['nonce'] and value['uid']==0 and value['pid']>1
             and value['operation']==op and value['sampled_ns']>0,'Policy probe identity/operation')
        need(value['cycle_start_ms']==base['cycle_start_ms']<base['cycle_end_ms']==value['cycle_end_ms'],
             'Policy cycle changed')
    need(base['sampled_ns']<installed['sampled_ns']<query['sampled_ns'],'Policy observation order')
    need(base['policies']==[] and len(installed['policies'])==1 and installed['policies']==query['policies'],
         'Finite policy ownership changed')
    p=installed['policies'][0]
    need(p['match_rule']==5 and p['meteredness']==-1 and p['limit']==case['absolute_limit']
         and all(p[k]==-1 for k in ('warning','last_limit_snooze','last_warning_snooze','last_rapid_snooze'))
         and p['metered'] and not p['inferred'],'Unexpected finite Ethernet policy')
    need(case['headroom']==8*1024*1024 and base['recorded_bytes']>0
         and base['recorded_bytes']<=installed['recorded_bytes']<=query['recorded_bytes']
         and case['absolute_limit']==base['recorded_bytes']+case['headroom']<1<<63,
         'Flushed recorded cycle usage was lost')
    a,b=case['before'],case['after']
    for k in ('ifindex','map_id','production_links','query'):need(a[k]==b[k],'Restart backend source changed')
    need(len(a['counters'])==len(b['counters'])==4 and all(0<=x<=y<1<<64 for x,y in zip(a['counters'],b['counters'])),
         'Restart accounting reset')
    for state in (a,b):
        q=state['quota']
        need(q['present'] and 0<=q['remaining']<=q['limit']<=case['headroom']
             and q['limit']>0 and q['generation']>0 and q['invalid']==q['contention']==0,
             'Finite allowance was regranted or backend failed')
        need(all(q[k]==a['quota'][k]>0 for k in ('map_id','drops_map_id')),'Quota source changed')
        need(state['quota_admitted']['map_id']==a['quota_admitted']['map_id']>0,'Admitted source changed')
    need(b['quota']['generation']>=a['quota']['generation']
         and a['quota_admitted']['bytes']<=b['quota_admitted']['bytes']<1<<64,'Quota state regressed')
    old,dead=case['listener_before'],case['listener_after']
    need(old==dict(pid=old['pid'],uid=0,netd_alive=True,deaths=0,death_ns=0,sampled_ns=old['sampled_ns'])
         and old['pid']>1 and old['sampled_ns']>0,'Original listener unavailable')
    need(dead==dict(old,netd_alive=False,deaths=1,death_ns=dead['death_ns'],sampled_ns=dead['sampled_ns'])
         and old['sampled_ns']<dead['death_ns']<=query['sampled_ns']
         and dead['death_ns']<=dead['sampled_ns']<query['sampled_ns']+30_000_000_000,
         'Exact old Binder death receipt missing')
    return dict(status='pass',recorded_bytes=query['recorded_bytes'],initial_recovered_limit=b['quota']['limit'])


def assess(case):
    result=assess_initial(case)
    a,b=case['fresh_listener_before'],case['fresh_listener_after']
    need(a==dict(pid=a['pid'],uid=0,netd_alive=True,deaths=0,death_ns=0,sampled_ns=a['sampled_ns'])
         and a['pid']>1 and a['pid']!=case['listener_before']['pid'] and a['sampled_ns']>case['listener_after']['sampled_ns']
         and b==dict(a,sampled_ns=b['sampled_ns']) and b['sampled_ns']>a['sampled_ns'],
         'Fresh listener is not a distinct live client')
    ready,done=case['packet_ready'],case['packet']
    need(ready['event']=='ready' and ready['uid']==ready['gid']==1001 and ready['pid']>1
         and int(ready['cap_eff'],16)==0 and ready['nonce']==case['nonce'],'Native restart packet privilege/identity')
    need(all(done[k]==ready[k] for k in ('uid','gid','pid','nonce','local','remote'))
         and done['event']=='finished' and done['attempted']==done['successful']+done['enobufs']==1
         and done['successful'] in (0,1) and done['enobufs'] in (0,1)
         and len(done['release_ns'])==1 and a['sampled_ns']<done['start_ns']<=done['release_ns'][0]<=done['end_ns'],
         'Native restart attempt changed or retried')
    automatic=case['automatic'];query,check=automatic['query'],automatic['check'];state=automatic['quota']
    for value in (query,check):
        need(value['operation']=='inspect' and value['nonce']==case['nonce'] and value['uid']==0
             and value['pid']>1 and value['policies']==case['installed']['policies']
             and value['cycle_start_ms']==case['baseline']['cycle_start_ms']
             and value['cycle_end_ms']==case['baseline']['cycle_end_ms'],'Automatic policy query changed or forced a poll')
    need(done['end_ns']<query['sampled_ns']<check['sampled_ns']
         and query['recorded_bytes']==check['recorded_bytes']>=case['query']['recorded_bytes'],
         'Recorded usage changed across the convergence snapshot')
    q=state['quota'];before=case['after']
    need(all(state[k]==before[k] for k in ('ifindex','map_id','production_links','query'))
         and all(q[k]==before['quota'][k] for k in ('map_id','drops_map_id'))
         and q['present'] and q['limit']==case['absolute_limit']-query['recorded_bytes']
         and 1<q['limit']<=case['headroom'] and 0<=q['remaining']<=q['limit']
         and q['generation']>=before['quota']['generation'] and q['invalid']==q['contention']==0,
         'Automatic readiness did not restore the calculated finite allowance')
    need(state['quota_admitted']['map_id']==before['quota_admitted']['map_id']
         and state['quota_admitted']['bytes']>=before['quota_admitted']['bytes'], 'Automatic admitted source changed')
    mode=re.findall(r'^\s*royd Ethernet quota readiness: received=(yes|no) conservative_used=(yes|no)$',case['readiness'],re.M)
    need(mode==[('yes','yes')],'Conservative guard and real callback readiness were not exercised')
    rows=case['fixture'];need(len(rows)<=1,'Unexpected restart fixture traffic')
    for row in rows:
        need(row['event']=='receive' and row['uid']==1001 and row['kind']==1 and row['step']==row['count']==1
             and row['sequence']==0 and row['peer']==ready['local']
             and row['sha256']==hashlib.sha256(packet(bytes.fromhex(case['nonce']),1,1001,0,1,1)).hexdigest(),
             'Restart fixture receipt is not the single owned packet')
    callbacks=case['callbacks']['callbacks']
    for number,row in enumerate(callbacks,1):
        need(row['sequence']==number and row['nonce']==case['nonce'] and row['caller_uid']==row['caller_pid']==0
             and row['name'] in ('eth0','globalAlert') and row['interface']=='eth0'
             and case['query']['sampled_ns']<=row['time_ns']<=b['sampled_ns'],'Invalid fresh callback receipt')
    return dict(result,calculated_remaining=q['limit'],packet_attempts=1,packet_receipts=len(rows),
        hard_receipts=sum(row['name']=='eth0' for row in callbacks),
        scope='Finite policy/history, conservative readiness, single native attempt and fresh listener; exact exhaustion matrix separate')


def replay(directory):
    load=lambda name:json.loads((directory/name).read_text())
    case=load('finite-restart-case.json');initial=load('initial-quota.json')
    bindings={'baseline':'restart-baseline.json','installed':'restart-installed.json','query':'restart-recovered.json',
        'after':'finite-recovered-quota.json','listener_before':'restart-listener-before.json',
        'listener_after':'restart-listener-after.json','packet_ready':'restart-packet-ready.json',
        'packet':'restart-packet.json','fresh_listener_before':'restart-fresh-listener-before.json',
        'fresh_listener_after':'restart-fresh-listener-after.json','callbacks':'restart-callbacks.json'}
    for key,name in bindings.items():need(case[key]==load(name),'Recovery case differs from raw source: '+key)
    need(case['before']==load('restart-install-samples.json')[-1]
         and case['automatic']==load('restart-automatic-samples.json')[-1]
         and case['readiness']==(directory/'npm-automatic.log').read_text()
         and case['fixture']==[json.loads(line) for line in (directory/'restart-fixture.jsonl').read_text().splitlines()],
         'Recovery case differs from saved observations')
    need(all(case['before']['quota'][k]==initial['quota'][k] for k in ('map_id','drops_map_id'))
         and case['before']['quota_admitted']['map_id']==initial['quota_admitted']['map_id'],
         'Recovery case differs from original owned maps')
    hashes=[]
    for name in ('restart-installed-netpolicy.xml','restart-recovered-netpolicy.xml','restart-automatic-netpolicy.xml'):
        raw=(directory/name).read_bytes();capture=load(name+'.capture.json');digest=hashlib.sha256(raw).hexdigest()
        need(raw and capture==dict(source='/data/system/netpolicy.xml',bytes=len(raw),sha256=digest),'Raw policy capture differs')
        for suffix in ('.source-before.log','.source-after.log'):
            need((directory/(name+suffix)).read_text().split()==[digest,'/data/system/netpolicy.xml'],'Live policy checksum differs')
        hashes.append(digest)
    need(len(set(hashes))==1,'Persisted policy changed across restart/readiness')
    need(load('restart-fixture-final.json')==dict(initial_drops=0,final_drops=0,errors=[]),
         'Restart fixture failed or lost packets')
    return assess(case)
