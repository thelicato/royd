import copy
import hashlib
import importlib.util
from pathlib import Path
import sys
import unittest

QUOTA=Path(__file__).resolve().parents[1]/'network-quota'
sys.path.insert(0,str(QUOTA))
from assess_policy_continuity import assess
from fixture import packet,IP_BYTES
from assess_policy_usage_test import case as usage_case
spec=importlib.util.spec_from_file_location('continuity_packet_fixture',QUOTA/'assess_test.py')
packets=importlib.util.module_from_spec(spec);spec.loader.exec_module(packets)


def case(admitted=2,charged=2):
    old=usage_case();initial=copy.deepcopy(packets.example()['before'])
    initial['post']['quota'].update(limit=2556,remaining=2556)
    initial['post']['quota_admitted']=dict(map_id=60,bytes=1000)
    after=copy.deepcopy(initial)
    for side,n in [('pre',1536),('post',admitted)]:
        value=after[side];value['counters'][2]+=1536;value['counters'][3]+=1536*IP_BYTES
        value['observed'][1].update(skbs=n,segments=n,raw_bytes=n*(IP_BYTES+14))
    after['post']['quota'].update(generation=21,limit=1,remaining=1)
    after['post']['quota_admitted']['bytes']+=charged*IP_BYTES
    ready=dict(event='ready',uid=1001,gid=1001,pid=500,nonce=old['nonce'],cap_eff='0',
               local='10.254.0.2:40000',remote='10.254.0.1:50000')
    done=dict(ready,event='finished',attempted=1536,successful=1536,enobufs=0,start_ns=1000,
              end_ns=3000,release_ns=list(range(1000,2536)))
    query=dict(old['installed'],operation='inspect',sampled_ns=400,recorded_bytes=86481+1536*IP_BYTES)
    callback=dict(sequence=1,nonce=old['nonce'],caller_uid=0,caller_pid=0,interface='eth0',name='eth0',time_ns=300)
    live=dict(netd_alive=True,pid=1234,uid=0,deaths=0,death_ns=0)
    value=dict(nonce=old['nonce'],absolute_limit=old['absolute_limit'],baseline=old['baseline'],installed=old['installed'],
               final_policy=query,before=initial,after=after,during=[copy.deepcopy(initial)],ready=ready,finished=done,
               callbacks=dict(sampled_ns=350,callbacks=[callback]),listener_before=dict(live,sampled_ns=90),
               listener_after=dict(live,sampled_ns=350))
    rows=[dict(event='receive',peer=ready['local'],uid=1001,step=1,sequence=n,count=64,kind=1,
               sha256=hashlib.sha256(packet(bytes.fromhex(old['nonce']),1,1001,n,64,1)).hexdigest())
          for n in range(admitted)]
    return value,rows


class ContinuousPolicyAssessment(unittest.TestCase):
    def test_two_fitting_packets_and_all_remaining_denied(self):
        result=assess(*case())
        self.assertEqual((result['attempted'],result['admitted'],result['denied']),(1536,2,1534))
        self.assertEqual(result['uncharged_admissions'],0)

    def test_reproduced_uncharged_bypass_and_fresh_allowance_regrant_fail(self):
        for charged in (2,18):
            with self.subTest(charged=charged),self.assertRaises(ValueError):assess(*case(18,charged))
        value,rows=case(0,0)
        with self.assertRaises(ValueError):assess(value,rows)

    def test_automatic_usage_may_coalesce_but_cannot_be_explicitly_polled(self):
        value,rows=case();value['final_policy']['recorded_bytes']=value['absolute_limit']
        self.assertEqual(assess(value,rows)['status'],'pass')
        value['final_policy']['operation']='poll'
        with self.assertRaises(ValueError):assess(value,rows)

    def test_healthy_source_and_real_identity_and_receipts_are_required(self):
        changes=[
            lambda v,r:v['ready'].update(cap_eff='1'),
            lambda v,r:v['ready'].update(uid=1000),
            lambda v,r:v['ready'].update(pid=1),
            lambda v,r:v['finished'].update(pid=501),
            lambda v,r:v['finished']['release_ns'].reverse(),
            lambda v,r:v['callbacks']['callbacks'].clear(),
            lambda v,r:v['callbacks']['callbacks'][0].update(name='globalAlert'),
            lambda v,r:v['callbacks']['callbacks'][0].update(caller_uid=1000),
            lambda v,r:v['callbacks']['callbacks'][0].update(time_ns=351),
            lambda v,r:v['after']['post']['quota'].update(map_id=99),
            lambda v,r:v['during'][0]['post']['quota'].update(present=False),
            lambda v,r:v['during'][0]['post']['quota'].update(limit=(1<<63)-1,remaining=(1<<63)-1),
            lambda v,r:v['after']['post']['quota'].update(contention=1),
            lambda v,r:v['after']['post']['quota_admitted'].update(bytes=3457),
            lambda v,r:v['after']['pre']['observed'][1].update(other_ip_skbs=1),
            lambda v,r:v['after']['pre']['observed'][1].update(gso_skbs=1),
            lambda v,r:v['after']['post'].update(map_id=99),
            lambda v,r:v['after']['post']['counters'].__setitem__(0,11),
            lambda v,r:v['final_policy'].update(recorded_bytes=86481),
            lambda v,r:v['final_policy'].update(cycle_end_ms=21),
            lambda v,r:v['listener_after'].update(deaths=1),
            lambda v,r:r.clear(),
            lambda v,r:r[0].update(sha256='0'*64),
        ]
        for change in changes:
            value,rows=case();change(value,rows)
            with self.subTest(change=change),self.assertRaises(ValueError):assess(value,rows)

    def test_global_receipts_are_retained_and_counted(self):
        value,rows=case();value['callbacks']['callbacks'].append(dict(value['callbacks']['callbacks'][0],sequence=2,name='globalAlert',time_ns=301))
        self.assertEqual(assess(value,rows)['global_receipts'],1)


if __name__=='__main__':unittest.main()
