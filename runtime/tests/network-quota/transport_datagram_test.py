import copy
import unittest
from assess_transport import assess_datagram


def example(kind):
    seg=kind=='segmented';step=8 if seg else 1;uid=1000 if seg else 0;phase=9 if seg else 10
    zero=dict(skbs=0,segments=0,gso_skbs=0,raw_bytes=0,other_ip_skbs=0,errors=0)
    base=dict(ifindex=2,map_id=17,production_links=[2,3],query=[[2,4,5,6],[3,7,8,9]],counters=[0]*4,observed=[zero.copy(),zero.copy()],tcp=[[],[]])
    before=dict(pre=copy.deepcopy(base),post=copy.deepcopy(base));after=copy.deepcopy(before)
    def stats(batches):
        return dict(skbs=batches,segments=batches*step,gso_skbs=batches if seg else 0,raw_bytes=batches*(step*1200+42),other_ip_skbs=0,errors=0)
    after['pre']['observed']=[stats(1),stats(2)];after['post']['observed']=[stats(1),stats(1)]
    after['pre']['counters']=[step,step*1228,2*step,2*step*1228]
    q=dict(present=True,map_id=31,drops_map_id=32,limit=2*step*1228+100,remaining=2*step*1228+100,generation=7,invalid=0,contention=0)
    before['post'].update(quota=q,quota_admitted=dict(map_id=33,bytes=100))
    after['post'].update(quota=dict(q,remaining=0),quota_admitted=dict(map_id=33,bytes=100+2*step*1228))
    fixture=dict(address='10.254.0.1:40000',nonce='00'*16)
    ready=dict(event='ready',uid=uid,gid=uid,pid=100,cap_eff='0' if seg else '2000',cgroup='0::/royd/init\n')
    w=dict(event='quota-datagram-blocked',uid=uid,phase=phase,attempted=2*step,received=step,payload_bytes=step*1200,segmented=seg,raw=not seg,local='10.254.0.2:41000',remote=fixture['address'],udp_socket=dict(socket_drops=0))
    hashes={9:'1e2c36c3fefccfff6e5e8196c15cdd8ebe1b9aef82b19e59f3bbf889a6ee18bc',10:'27e3cc253debaf2ea8150c1978aa0e0ba266125ae432bee47fd203935f105c5a'}
    receipt=dict(event='quota-udp-batch',phase=phase,uid=uid,first_sequence=0,packets=step,segmented=seg,peer=w['local'],payload_sha256=hashes[phase])
    return dict(kind=kind,phase=phase,fixture=fixture,ready=ready,worker=w,before=before,after=after,server_receipts=[receipt])

class DatagramAssessment(unittest.TestCase):
    def test_exact_segmented_and_raw_crossing(self):
        for kind in ['segmented','raw']:
            with self.subTest(kind=kind):
                r=assess_datagram(example(kind));self.assertEqual(r['status'],'pass');self.assertEqual(r['discarded_tail'],100)
    def test_timeout_without_packet_receipts_cannot_pass(self):
        for kind in ['segmented','raw']:
            x=example(kind);x['server_receipts']=[]
            with self.assertRaises(ValueError):assess_datagram(x)
    def test_partial_aggregate_or_extra_traffic_cannot_pass(self):
        for mutate in [lambda x:x['after']['post']['observed'][1].__setitem__('segments',9),lambda x:x['after']['pre']['observed'][0].__setitem__('other_ip_skbs',1),lambda x:x['after']['post']['quota'].__setitem__('generation',8),lambda x:x['worker']['udp_socket'].__setitem__('socket_drops',1)]:
            x=example('segmented');mutate(x)
            with self.assertRaises(ValueError):assess_datagram(x)

if __name__=='__main__':unittest.main()
