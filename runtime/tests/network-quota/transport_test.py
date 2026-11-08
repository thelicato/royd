import copy
import unittest

def records(source,destination,source_port,destination_port):
    base=0xffffffe0
    def row(sequence,length,tcp_len=32,flags=16,segmented=False):
        return dict(skb_len=14+20+tcp_len+length,ip_len=20,ip_total=20+tcp_len+length,
                    tcp_len=tcp_len,sequence=sequence%(1<<32),gso_size=1448 if segmented else 0,
                    gso_segs=23 if segmented else 1,flags=flags,source=source,destination=destination,
                    source_port=source_port,destination_port=destination_port)
    return ([row(base,0,tcp_len=40,flags=2)]
            +[row(base+1+offset,32768,segmented=True) for offset in range(0,1<<20,32768)]
            +[row(base+1+(1<<20),0,flags=17),row(base+2+(1<<20),0)])
from assess_transport import assess,payload_hash,STREAM_BYTES

MAXIMUM=(1<<63)-1

def case():
    zero=dict(skbs=0,segments=0,gso_skbs=0,raw_bytes=0,other_ip_skbs=0,errors=0)
    def view(tcp,counters,remaining,generation,admitted):
        base=dict(ifindex=2,map_id=17,production_links=[2,3],query=[[2,4,5,6,7,8],[3,9,10,11,12,13]],observed=[zero.copy(),zero.copy()],tcp=copy.deepcopy(tcp),counters=list(counters))
        post=copy.deepcopy(base);post['quota']=dict(present=True,map_id=31,drops_map_id=32,limit=50000 if generation==1 else MAXIMUM,remaining=remaining,generation=generation,invalid=0,contention=0);post['quota_admitted']=dict(map_id=33,bytes=1000+admitted)
        return dict(pre=base,post=post)
    allrows=[[],[]];workers=[];receipts=[];fixture=dict(tcp_address='10.254.0.1:45000',nonce='00'*16)
    for uid,cpu,port in [(0,0,41000),(1000,1,41001)]:
        a=records(0x0afe0001,0x0afe0002,45000,port);b=records(0x0afe0002,0x0afe0001,port,45000)
        for row in a:row['cpu']=2
        for row in b:row['cpu']=cpu
        allrows[0]+=a;allrows[1]+=b
        hashes={key:payload_hash(fixture['nonce'],uid,reply) for key,reply in [('upload_sha256',0),('download_sha256',1)]}
        local=f'10.254.0.2:{port}'
        workers.append(dict(event='tcp-complete',uid=uid,phase=7,payload_bytes=STREAM_BYTES,start_ns=100+cpu,end_ns=1000+cpu,local=local,remote=fixture['tcp_address'],ready=dict(event='ready',uid=uid,gid=uid,pid=100+uid,cap_eff='0',cgroup='0::/royd/init\n'),pinned_cpu=cpu,actual_cpu_list=str(cpu),**hashes))
        receipts.append(dict(event='tcp-complete',uid=uid,phase=7,payload_bytes=STREAM_BYTES,peer=local,**hashes))
    heldpost=[[allrows[0][0]],[allrows[1][0],allrows[1][1]]]
    heldpre=copy.deepcopy(heldpost);heldpre[1].append(copy.deepcopy(allrows[1][2]))
    blockedpre=copy.deepcopy(heldpre);retry=copy.deepcopy(allrows[1][2]);retry.update(skb_len=1514,ip_total=1500,gso_size=0,gso_segs=1);blockedpre[1].append(retry)
    blockedpre[1].append(copy.deepcopy(next(r for r in allrows[1] if r['source_port']==41001 and r['flags']==2)))
    rest=[allrows[0][1:],allrows[1][2:]]
    finalpost=[copy.deepcopy(heldpost[d]+rest[d]) for d in [0,1]]
    finalpre=[copy.deepcopy(blockedpre[d]+rest[d]) for d in [0,1]]
    before=view([[],[]],[7,700,9,900],50000,1,0)
    held=view(heldpre,[8,760,56,68888],0,1,34084);held['post']['tcp']=copy.deepcopy(heldpost)
    blocked=view(blockedpre,[8,760,58,70448],0,1,34084);blocked['post']['tcp']=copy.deepcopy(heldpost)
    restored=view(blockedpre,[8,760,58,70448],MAXIMUM,2,34084);restored['post']['tcp']=copy.deepcopy(heldpost)
    after=view(finalpre,[1485,2174724,1512,2210448],MAXIMUM-(4348048-34084),2,4348048);after['post']['tcp']=finalpost
    restoration=dict(operation='set',bytes=MAXIMUM,uid=0,pid=50,error=0,denied=False,finished_ns=5_000_000_001)
    return dict(limit=50000,fixture=fixture,workers=workers,server_receipts=receipts,before=before,held=held,blocked=blocked,restored=restored,after=after,restoration=restoration,opened_boottime_ns=1)

class TransportAssessment(unittest.TestCase):
    def test_known_wire_totals_with_intentional_retransmission(self):
        r=assess(case());self.assertEqual(r['status'],'pass');self.assertEqual(r['old_generation_admitted'],34084);self.assertEqual(r['rejected_gso_aggregates'],1);self.assertEqual(r['post'][1]['cpus'],[0,1])
    def test_actual_failures_cannot_be_relabelled(self):
        mutations={
          'leaked_while_exhausted':lambda x:x['blocked']['post']['tcp'][1].append(copy.deepcopy(x['after']['post']['tcp'][1][2])),
          'counter_undercharge':lambda x:x['after']['post']['quota_admitted'].__setitem__('bytes',x['after']['post']['quota_admitted']['bytes']-1),
          'finite_overspend':lambda x:x['after']['post']['quota'].__setitem__('remaining',MAXIMUM-1),
          'wrong_payload':lambda x:x['workers'][0].__setitem__('upload_sha256','0'*64),
          'quota_source_replaced':lambda x:x['blocked']['post']['quota'].__setitem__('map_id',99),
          'changed_finite_generation':lambda x:x['blocked']['post']['quota'].__setitem__('generation',9),
          'no_parallel_transfer':lambda x:x['workers'][1].__setitem__('start_ns',2000),
          'privileged_system_worker':lambda x:x['workers'][1]['ready'].__setitem__('cap_eff','2000'),
          'bad_segment_count':lambda x:x['after']['post']['tcp'][1][1].__setitem__('gso_segs',22),
          'late_restoration':lambda x:x['restoration'].__setitem__('finished_ns',5_000_000_002),
          'unrecorded_reset':lambda x:x['after']['post']['quota'].__setitem__('generation',3),
          'wrong_fixture_phase':lambda x:x['server_receipts'][0].__setitem__('phase',6),
          'wrong_worker_type':lambda x:x['workers'][0].__setitem__('event','ready'),
          'single_finite_cpu':lambda x:[r.__setitem__('cpu',0) for r in x['blocked']['pre']['tcp'][1]],
        }
        for name,mutate in mutations.items():
            with self.subTest(name=name):
                x=case();mutate(x)
                with self.assertRaises(ValueError):assess(x)

if __name__=='__main__':unittest.main()
