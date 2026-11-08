"""Independent IP-cost and full-stream receipts for deliberate quota interruption."""
import ipaddress
import struct
import hashlib
from collections import Counter

STREAM_BYTES = 1 << 20
TCP_FIELDS = {'skb_len','ip_len','ip_total','tcp_len','sequence','gso_size','gso_segs',
              'flags','source','destination','source_port','destination_port','cpu'}

def need(value, reason):
    if not value: raise ValueError(reason)

def tcp_cost(row):
    need(set(row)==TCP_FIELDS,'TCP metadata schema')
    need(all(type(x) is int and 0<=x<1<<32 for x in row.values()),'TCP unsigned metadata')
    need(row['ip_len']==20 and 20<=row['tcp_len']<=60 and row['tcp_len']%4==0,'TCP header lengths')
    header=row['ip_len']+row['tcp_len']
    need(header<=row['ip_total']<=65535 and row['skb_len']>=14+header,'TCP/IP frame bounds')
    need(not row['flags']&4,'TCP reset')
    if row['gso_size']:
        payload=row['skb_len']-14-header
        segments=max(1,(payload+row['gso_size']-1)//row['gso_size'])
    else:
        need(row['ip_total']<=row['skb_len']-14,'IPv4 exceeds captured skb')
        payload=row['ip_total']-header;segments=1
    if segments>1: need(row['gso_segs']==segments and row['gso_size']>0,'TCP segmentation metadata')
    else: need(row['gso_segs'] in (0,1) and payload==row['ip_total']-header,'Unsegmented TCP length')
    return dict(packets=segments,ip_bytes=payload+segments*header,payload=payload,gso=segments>1)

def delta(start,end):
    need(len(start)==len(end)==2,'TCP direction count')
    rows=[]
    for a,b in zip(start,end):
        need(len(a)<=len(b)<=4096 and b[:len(a)]==a,'TCP header ledger changed or overflowed')
        rows.append(b[len(a):])
    return rows

def totals(rows):
    result=[]
    for direction in rows:
        values=[tcp_cost(r) for r in direction]
        result.append(dict(packets=sum(x['packets'] for x in values),ip_bytes=sum(x['ip_bytes'] for x in values),
                           gso_skbs=sum(x['gso'] for x in values),cpus=sorted({r['cpu'] for r in direction})))
    return result

def source(before,after):
    for k in ['ifindex','map_id','production_links','query']:
        need(before[k]==after[k],'TCP source identity changed: '+k)
    need(before['observed']==after['observed'],'UDP/unrelated IP/observer error during TCP window')
    for side in after['observed']:
        need(side['errors']==0,'TCP observer fault')

def payload_hash(nonce,uid,reply):
    p=bytes.fromhex(nonce)+struct.pack('!III',7,uid,STREAM_BYTES)+bytes([reply,0,0,0])
    p+=bytes((i^7^uid^reply)&255 for i in range(32,STREAM_BYTES))
    return hashlib.sha256(p).hexdigest()

def endpoint(value):
    ip,port=value.rsplit(':',1);a=ipaddress.IPv4Address(ip);need(a.is_private and 0<int(port)<=65535,'Private TCP endpoint')
    return int(a),int(port)

def stream_coverage(records):
    syn=[r for r in records if r['flags']&2];need(syn,'Missing TCP handshake')
    need(len({r['sequence'] for r in syn})==1,'Changed TCP initial sequence')
    base=(syn[0]['sequence']+1)%(1<<32);intervals=[];fins=[]
    for r in records:
        v=tcp_cost(r);length=v['payload'];offset=(r['sequence']-base)%(1<<32)
        if length:
            need(not r['flags']&2 and offset+length<=STREAM_BYTES,'TCP payload outside stream')
            intervals.append((offset,offset+length))
        if r['flags']&1:fins.append(offset+length)
    need(fins and all(x==STREAM_BYTES for x in fins),'TCP graceful close boundary')
    covered=0
    for lo,hi in sorted(intervals):
        need(lo<=covered and lo<hi,'TCP stream coverage gap');covered=max(covered,hi)
    need(covered==STREAM_BYTES,'Incomplete TCP stream')

def assess(case):
    before,held,blocked,restored,after=[case[x] for x in ['before','held','blocked','restored','after']]
    restoration=case['restoration']
    need(restoration['operation']=='set' and restoration['bytes']==(1<<63)-1
         and restoration['uid']==0 and restoration['pid']>1 and restoration['error']==0
         and not restoration['denied'],'TCP restoration Binder receipt')
    need(0<restoration['finished_ns']-case['opened_boottime_ns']<=5_000_000_000,
         'TCP restoration exceeded the host orchestration bound')
    for snapshot in [held,blocked,restored,after]:
        for role in ['pre','post']:source(before[role],snapshot[role])
    for snapshot in [before,held,blocked,restored,after]:
        for key in ['map_id','drops_map_id']:need(snapshot['post']['quota'][key]==before['post']['quota'][key],'TCP quota source changed')
        need(snapshot['post']['quota_admitted']['map_id']==before['post']['quota_admitted']['map_id'],'TCP admitted map changed')
    for a,b in [(before,held),(held,blocked),(blocked,restored),(restored,after)]:
        for role in ['pre','post']:delta(a[role]['tcp'],b[role]['tcp'])
    # Real held-policy traffic must still reach the pre hook and never pass the post hook.
    held_pre=delta(held['pre']['tcp'],blocked['pre']['tcp']);held_post=delta(held['post']['tcp'],blocked['post']['tcp'])
    need(sum(map(len,held_pre))>0 and not any(held_post),'No observed TCP denial while quota held at zero')
    for snapshot in [held,blocked]:
        q=snapshot['post']['quota'];need(q['present'] and q['limit']==case['limit'] and q['remaining']==0,'TCP finite policy not exhausted')
        need(q['generation']==before['post']['quota']['generation'] and q['invalid']==q['contention']==0,'TCP generation/backend fault')
    final=after['post']['quota'];initial=before['post']['quota'];need(initial['present'] and initial['limit']==initial['remaining']==case['limit'],'TCP finite registration')
    need(final['present'] and final['limit']==(1<<63)-1 and 0<=final['remaining']<=(1<<63)-1 and final['generation']>initial['generation'] and final['invalid']==final['contention']==0,'TCP restoration registration')
    q=restored['post']['quota']
    need(q['present'] and q['limit']==final['limit'] and q['generation']==final['generation']
         and final['remaining']<=q['remaining']<=q['limit'] and q['invalid']==q['contention']==0,
         'Unrecorded quota generation/reset after TCP restoration')
    pre_rows=delta(before['pre']['tcp'],after['pre']['tcp']);pre=totals(pre_rows);post_rows=delta(before['post']['tcp'],after['post']['tcp']);post=totals(post_rows)
    denied_gso=0
    for incoming,outgoing in zip(pre_rows,post_rows):
        key=lambda r:tuple((k,r[k]) for k in sorted(TCP_FIELDS-{'cpu'}))
        counts=Counter(map(key,incoming));accepted=Counter(map(key,outgoing))
        need(all(counts[k]>=v for k,v in accepted.items()),'Post-hook TCP record lacks a pre-hook counterpart')
        rejected=counts-accepted
        for row in incoming:
            k=key(row)
            if rejected[k] and tcp_cost(row)['gso']:
                denied_gso+=1;rejected[k]-=1
    need(denied_gso>0,'No real rejected TCP GSO aggregate')
    need(all(x['gso_skbs']>0 for x in post),'Missing actual admitted TCP segmentation in a direction')
    need(len(post[1]['cpus'])>=2,'No actual multi-CPU egress observation')
    finite_rows=delta(before['pre']['tcp'],blocked['pre']['tcp'])
    finite_cpus=sorted({r['cpu'] for r in finite_rows[1]})
    need(len(finite_cpus)>=2,'No actual multi-CPU egress under the finite policy')
    accounting=[y-x for x,y in zip(before['pre']['counters'],after['pre']['counters'])]
    need(accounting==[pre[0]['packets'],pre[0]['ip_bytes'],pre[1]['packets'],pre[1]['ip_bytes']],'TCP pre-quota accounting differs from independent metadata')
    a,b=before['post']['quota_admitted'],after['post']['quota_admitted'];need(a['map_id']==b['map_id'] and b['bytes']>=a['bytes'],'TCP admitted source')
    admitted=b['bytes']-a['bytes'];need(admitted==sum(x['ip_bytes'] for x in post),'TCP admitted bytes differ from independent post hook')
    new_use=((1<<63)-1)-final['remaining'];old_use=admitted-new_use;need(0<=old_use<=case['limit'],'TCP exceeded old shared generation allowance')
    # Allow retransmission in this deliberately interrupted workload, preserving every record.
    server=endpoint(case['fixture']['tcp_address']);flows={};workers=case['workers'];need(len(workers)==2 and {x['uid'] for x in workers}=={0,1000},'Distinct TCP worker UIDs')
    receipts=case['server_receipts'];need(len(receipts)==2,'TCP server receipt count')
    need(len({x['ready']['pid'] for x in workers})==2 and len({x['pinned_cpu'] for x in workers})==2,'TCP workers share identity or pinned CPU')
    need(max(x['start_ns'] for x in workers)<min(x['end_ns'] for x in workers),'TCP transfer intervals did not overlap')
    for w in workers:
        ready=w['ready'];need(ready['event']=='ready' and ready['uid']==ready['gid']==w['uid'] and ready['pid']>1 and ready['cgroup'].strip()=='0::/royd/init','TCP ready identity')
        need(type(w['pinned_cpu']) is int and w['pinned_cpu']>=0 and w['actual_cpu_list']==str(w['pinned_cpu']),'TCP pinned affinity')
        if w['uid']==1000:need(int(ready['cap_eff'],16)==0,'TCP native system UID capabilities')
        uid=w['uid'];need(0<w['start_ns']<w['end_ns'],'TCP transfer timestamp bounds');need(w['event']=='tcp-complete' and w['phase']==7 and w['payload_bytes']==STREAM_BYTES and endpoint(w['remote'])==server,'TCP worker receipt')
        matching=[x for x in receipts if x['uid']==uid];need(len(matching)==1 and matching[0]['peer']==w['local'],'TCP peer receipt')
        need(matching[0]['event']=='tcp-complete' and matching[0]['phase']==7
             and matching[0]['payload_bytes']==STREAM_BYTES,'TCP fixture receipt identity')
        for key,reply in [('upload_sha256',0),('download_sha256',1)]:need(w[key]==matching[0][key]==payload_hash(case['fixture']['nonce'],uid,reply),'TCP payload integrity')
        local=endpoint(w['local']);need(local not in flows,'TCP workers share an endpoint')
        need(any((r['source'],r['source_port'])==local and (r['destination'],r['destination_port'])==server
                 for r in finite_rows[1]),'Worker did not compete under the finite policy')
        flows[local]=[[],[]]
    for direction,rows in enumerate(post_rows):
        for r in rows:
            local=(r['destination'],r['destination_port']) if direction==0 else (r['source'],r['source_port']);remote=(r['source'],r['source_port']) if direction==0 else (r['destination'],r['destination_port'])
            need(local in flows and remote==server,'Foreign TCP flow');flows[local][direction].append(r)
    for directions in flows.values():
        for records in directions:stream_coverage(records)
    return dict(status='pass',scope='real-shared-finite-tcp-quota-with-recovery',pre=pre,post=post,rejected_gso_aggregates=denied_gso,old_generation_admitted=old_use,new_generation_admitted=new_use,finite_egress_cpus=finite_cpus,
                limitation='Overlapping flows and multiple observed packet CPUs, not instruction-level proof of a CAS race or a performance comparison.')

def udp_cost(value):
    need(set(value)=={'skbs','segments','gso_skbs','raw_bytes','other_ip_skbs','errors'},'UDP observer schema')
    need(all(type(v) is int and v>=0 for v in value.values()),'UDP negative metadata')
    need(value['segments']>=value['skbs']>=value['gso_skbs'],'UDP aggregation bounds')
    return value['raw_bytes']-14*value['skbs']+28*(value['segments']-value['skbs'])

def go_datagram(nonce,phase,uid,seq,count,segmented):
    header=bytes.fromhex(nonce)+struct.pack('!IIIIB',phase,uid,seq,count,int(segmented))
    return header+bytes((i+seq+uid)&255 for i in range(33,1200))

def assess_datagram(case):
    before,after=case['before'],case['after'];w=case['worker'];ready=case['ready'];seg=case['kind']=='segmented';step=8 if seg else 1;uid=1000 if seg else 0
    need(case['kind'] in ('segmented','raw'),'Datagram scope')
    need(ready['event']=='ready' and ready['uid']==ready['gid']==uid and ready['pid']>1 and ready['cgroup'].strip()=='0::/royd/init','Datagram ready identity')
    if uid==1000:need(int(ready['cap_eff'],16)==0,'Datagram system UID capabilities')
    else:need(int(ready['cap_eff'],16)&(1<<13),'Raw socket capability evidence')
    need(w['event']=='quota-datagram-blocked' and w['uid']==uid and w['phase']==case['phase'] and w['attempted']==2*step and w['received']==step and w['payload_bytes']==step*1200 and w['segmented']==seg and w['raw']==(not seg),'Typed datagram receipt')
    need(w['udp_socket'].get('socket_drops')==0 and 'error' not in w['udp_socket'],'Owned datagram socket loss/diagnostic failure')
    need(w['remote']==case['fixture']['address'] and endpoint(w['local'])!=endpoint(w['remote']),'Datagram endpoint')
    receipts=case['server_receipts'];need(len(receipts)==1,'Unexpected fixture batch count')
    r=receipts[0];expected=hashlib.sha256(b''.join(go_datagram(case['fixture']['nonce'],case['phase'],uid,i,2*step,seg) for i in range(step))).hexdigest()
    need(r['event']=='quota-udp-batch' and r['phase']==case['phase'] and r['uid']==uid and r['first_sequence']==0 and r['packets']==step and r['segmented']==seg and r['peer']==w['local'] and r['payload_sha256']==expected,'Independent fixture datagram receipt')
    observed={}
    for role in ['pre','post']:
        a,b=before[role],after[role]
        for key in ['ifindex','map_id','production_links','query']:need(a[key]==b[key],'Datagram source identity')
        need(a['tcp']==b['tcp'],'TCP/foreign traffic during datagram window')
        changes=[]
        for av,bv in zip(a['observed'],b['observed']):
            d={k:bv[k]-av[k] for k in av};need(all(x>=0 for x in d.values()) and d['errors']==d['other_ip_skbs']==0,'Unrelated IP or datagram observer error');udp_cost(d);changes.append(d)
        observed[role]=changes
    need([x['segments'] for x in observed['pre']]==[step,2*step] and [x['segments'] for x in observed['post']]==[step,step],'Wrong datagram admission/drop boundary')
    if seg:
        need(observed['pre'][1]['skbs']==observed['pre'][1]['gso_skbs']==2 and observed['post'][1]['skbs']==observed['post'][1]['gso_skbs']==1,'No whole segmented egress aggregate rejected')
        need(observed['pre'][0]['gso_skbs']>0 and observed['post'][0]['gso_skbs']>0,'Missing actual segmented ingress')
    charges={k:[udp_cost(x) for x in rows] for k,rows in observed.items()};need(charges=={'pre':[step*1228,2*step*1228],'post':[step*1228,step*1228]},'UDP replicated-header cost')
    accounting=[y-x for x,y in zip(before['pre']['counters'],after['pre']['counters'])];need(accounting==[step,step*1228,2*step,2*step*1228],'UDP accounting includes wrong traffic')
    qa,qb=before['post']['quota'],after['post']['quota']
    for key in ['map_id','drops_map_id']:need(qa[key]==qb[key],'Datagram quota source changed')
    limit=2*step*1228+100
    need(qa['present'] and qb['present'] and qa['limit']==qa['remaining']==qb['limit']==limit and qb['remaining']==0 and qa['generation']==qb['generation'],'Datagram quota generation/crossing')
    need(qa['invalid']==qa['contention']==qb['invalid']==qb['contention']==0,'Datagram backend fault')
    aa,ab=before['post']['quota_admitted'],after['post']['quota_admitted'];need(aa['map_id']==ab['map_id'] and ab['bytes']-aa['bytes']==2*step*1228,'Rejected aggregate/tail charged as admitted')
    return dict(status='pass',scope='finite-quota-'+case['kind'],attempted_egress=2*step,admitted_egress=step,admitted_ingress=step,rejected_egress=step,discarded_tail=100,observations=observed)
