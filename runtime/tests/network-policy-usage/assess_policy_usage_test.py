import copy
import unittest
from assess_policy_usage import assess, IP_BYTES


def case():
    common=dict(nonce='a'*32,uid=0,pid=100,cycle_start_ms=10,cycle_end_ms=20,policies=[])
    policy=dict(match_rule=5,meteredness=-1,limit=89037,warning=-1,last_limit_snooze=-1,last_rapid_snooze=-1,
                last_warning_snooze=-1,metered=True,inferred=False,cycle='current')
    base=dict(common,operation='poll',sampled_ns=100,recorded_bytes=86481)
    installed=dict(common,operation='set',sampled_ns=200,recorded_bytes=86481,policies=[policy])
    polled=dict(installed,operation='poll',sampled_ns=300,recorded_bytes=86481+2*IP_BYTES)
    def snapshot(generation,limit,remaining,counters,used):
        p=dict(ifindex=2,map_id=10,production_links=[1,2],query=[[1,3],[2,4]],counters=counters,
               quota=dict(present=True,map_id=20,drops_map_id=21,generation=generation,limit=limit,
                          remaining=remaining,invalid=0,contention=0),quota_admitted=dict(map_id=30,bytes=used))
        return dict(pre=dict(counters=counters),post=p)
    return dict(nonce='a'*32,absolute_limit=89037,baseline=base,installed=installed,polled=polled,
                before=snapshot(1,2556,2556,[10,10000,20,20000],1000),
                consumed=snapshot(1,2556,100,[11,11228,21,21228],3456),
                after=snapshot(2,100,100,[11,11228,21,21228],3456))


class PolicyUsageAssessment(unittest.TestCase):
    def test_exact_recorded_usage_deduction_and_recalculation(self):
        result=assess(case())
        self.assertEqual(result['initial_remaining'],2556)
        self.assertEqual(result['recalculated_remaining'],100)
        self.assertEqual(result['admitted_bytes'],2456)

    def test_reproduced_zero_usage_and_regranted_allowance_are_rejected(self):
        for stage in ('before','after'):
            value=case();value[stage]['post']['quota'].update(limit=89037,remaining=89037)
            with self.subTest(stage=stage),self.assertRaises(ValueError):assess(value)

    def test_wrong_policy_source_cycle_and_unrelated_traffic_cannot_pass(self):
        changes=[
            lambda x:x['polled'].update(uid=1000),
            lambda x:x['polled'].update(cycle_start_ms=11),
            lambda x:x['polled'].update(recorded_bytes=86481),
            lambda x:x['after']['post']['quota'].update(map_id=99),
            lambda x:x['after']['post']['quota_admitted'].update(bytes=3457),
            lambda x:x['after']['post'].update(counters=[11,11229,21,21228]),
            lambda x:x['after']['post']['quota'].update(contention=1),
        ]
        for change in changes:
            value=copy.deepcopy(case());change(value)
            with self.subTest(change=change),self.assertRaises(ValueError):assess(value)


if __name__=='__main__':unittest.main()
