import copy,sys,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'network-quota'))
from assess_policy_continuity import assess as assess_plain
from assess_policy_concurrent import assess
from assess_policy_continuity_test import case as continuity_case


def case():
    value,receipts=continuity_case();original=value['callbacks']['callbacks'][0]
    value['callbacks']=dict(sampled_ns=1_000_005_000,callbacks=[
        dict(original,sequence=1,name='eth0Alert',time_ns=1100),
        dict(original,sequence=2,time_ns=1150),
        dict(original,sequence=3,name='globalAlert',time_ns=1200)])
    value['listener_after']['sampled_ns']=1_000_005_000
    value['final_policy']['sampled_ns']=1_000_006_000
    def snapshot(count):
        result=copy.deepcopy(value['after'])
        for side in ('pre','post'):
            old=value['before'][side]
            result[side]['counters']=[old['counters'][0],old['counters'][1],old['counters'][2]+count,old['counters'][3]+count*1228]
        result['pre']['observed'][1].update(skbs=count,segments=count,raw_bytes=count*1242)
        return result
    initial=dict(generation=0,bytes=0,armed=False,committed=0,error=0)
    armed=dict(generation=1,bytes=1228,armed=True,committed=0,error=0)
    fired=dict(armed,armed=False,committed=1);replacement=dict(fired,generation=2,armed=True)
    receipt=dict(nonce=value['nonce'],uid=0,pid=value['listener_before']['pid'],operation='set-alert',bytes=1228,error=0,denied=False)
    value['associated']=dict(
        arm=dict(before=copy.deepcopy(value['before']),after=copy.deepcopy(value['before']),
            before_state=initial,after_state=armed,receipt=receipt),
        rearm=dict(before=snapshot(400),after=snapshot(800),before_state=fired,after_state=replacement,
            receipt=copy.deepcopy(receipt),start_ns=1500,end_ns=1600),
        quiet=dict(before=copy.deepcopy(value['after']),after=copy.deepcopy(value['after']),
            before_state=replacement,after_state=copy.deepcopy(replacement),start_ns=4000,end_ns=1_000_004_000,
            callbacks_before=copy.deepcopy(value['callbacks']),callbacks_after=copy.deepcopy(value['callbacks'])))
    return value,receipts


class ConcurrentPolicyAssessment(unittest.TestCase):
    def test_all_three_receipt_types_and_live_replacement(self):
        result=assess(*case())
        self.assertEqual(result['packets']['admitted'],2)
        self.assertEqual(result['associated']['associated_receipts'],1)
        self.assertGreater(result['associated']['later_attempts'],0)

    def test_plain_gate_still_rejects_an_associated_receipt(self):
        with self.assertRaises(ValueError):assess_plain(*case())

    def test_uncharged_admission_and_noise_are_still_rejected(self):
        changes=[lambda v:v['after']['post']['quota_admitted'].update(bytes=5000),
            lambda v:v['after']['pre']['observed'][1].update(other_ip_skbs=1),
            lambda v:v['after']['post']['quota'].update(limit=(1<<63)-1,remaining=(1<<63)-1)]
        for change in changes:
            value,rows=case();change(value)
            with self.subTest(change=change),self.assertRaises(ValueError):assess(value,rows)

    def test_rearm_without_later_attempts_or_real_receipts_cannot_pass(self):
        changes=[
            lambda v:v['associated']['rearm'].update(end_ns=3001),
            lambda v:v['associated']['rearm']['before']['pre']['observed'][1].update(skbs=1536),
            lambda v:v['associated']['rearm']['after_state'].update(armed=False),
            lambda v:v['associated']['rearm']['receipt'].update(uid=1000),
            lambda v:v['associated']['rearm']['receipt'].update(pid=999),
            lambda v:v['associated']['rearm']['before']['post']['quota_admitted'].update(bytes=4000),
            lambda v:v['associated']['quiet']['after_state'].update(committed=2),
            lambda v:v['associated']['quiet']['after']['pre']['counters'].__setitem__(0,1),
            lambda v:v['associated']['quiet'].update(end_ns=5000),
            lambda v:v['callbacks']['callbacks'][0].update(caller_uid=1000),
            lambda v:v['callbacks']['callbacks'][0].update(name='eth0'),
            lambda v:v['callbacks']['callbacks'][2].update(name='eth0'),
        ]
        for change in changes:
            value,rows=case();change(value)
            with self.subTest(change=change),self.assertRaises(ValueError):assess(value,rows)


if __name__=='__main__':unittest.main()
