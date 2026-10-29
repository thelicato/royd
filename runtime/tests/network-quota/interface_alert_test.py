import copy
import json
import os
import subprocess
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch, Mock
from assess import assess_flow
from assess_test import example
from interface_alert import AlertTrial, assess_alert_flow, receipts, no_traffic, ordered_usage, MAXIMUM, IP_BYTES


def flow(label='finite-b-dropped', passed=0):
    value = example(passed=passed)
    value['label'] = label
    value['before']['post']['quota_admitted'] = dict(map_id=60,bytes=100)
    value['after']['post']['quota_admitted'] = dict(map_id=60,bytes=100+passed*IP_BYTES)
    if label == 'first-b-cross':
        value['before']['post']['quota'].update(limit=MAXIMUM,remaining=MAXIMUM)
        value['after']['post']['quota'].update(limit=MAXIMUM,remaining=MAXIMUM-IP_BYTES)
        value['remaining'] = MAXIMUM-IP_BYTES
    return value


class AlertPackets(unittest.TestCase):
    def test_finite_admitted_and_whole_drop(self):
        for passed in (0,1):
            self.assertEqual(assess_alert_flow(flow(passed=passed))['admitted'],passed)

    def test_original_gate_still_rejects_callback_quota_replacement(self):
        item = flow('first-b-cross',1)
        item['after']['post']['quota'].update(generation=21,remaining=MAXIMUM)
        self.assertEqual(assess_alert_flow(item)['admitted'],1)
        with self.assertRaises(ValueError):assess_flow(item)

    def test_finite_counter_corruption_rejected(self):
        mutations = [
            lambda v:v['after']['post']['quota_admitted'].update(map_id=61),
            lambda v:v['after']['post']['quota_admitted'].update(bytes=200),
            lambda v:v['after']['post']['quota_admitted'].update(bytes=99),
            lambda v:v['after']['post']['quota'].update(generation=21),
            lambda v:v['after']['post']['quota'].update(contention=1),
            lambda v:v['after']['pre']['observed'][1].update(other_ip_skbs=1),
            lambda v:v['after']['post']['observed'][1].update(skbs=1),
        ]
        for mutate in mutations:
            with self.subTest(mutate=mutate):
                item = flow();mutate(item)
                with self.assertRaises(ValueError):assess_alert_flow(item)

    def test_callback_replacement_cannot_hide_finite_or_broken_state(self):
        for field,value in [('present',False),('limit',10000),('generation',0),('remaining',MAXIMUM+1),
                            ('invalid',1),('contention',1),('map_id',0),('drops_map_id',99)]:
            item = flow('first-b-cross',1);item['after']['post']['quota'][field] = value
            with self.subTest(field=field),self.assertRaises(ValueError):assess_alert_flow(item)

    def test_callback_still_requires_all_packet_receipts(self):
        item = flow('first-b-cross',1);item['fixture'] = []
        with self.assertRaises(ValueError):assess_alert_flow(item)

    def test_callback_replay_cannot_conceal_unaccounted_usage(self):
        item = flow('first-b-cross',1)
        item['after']['post']['quota'].update(generation=21,remaining=100)
        with self.assertRaisesRegex(ValueError,'replayed MAX debit'):assess_alert_flow(item)

    def test_removed_quota_must_not_increase_admitted_counter(self):
        item = flow(passed=1)
        for side in ('before','after'):
            item[side]['post']['quota'].update(present=False,limit=0,remaining=0,generation=0)
        item['after']['post']['quota_admitted']['bytes'] = 100
        self.assertEqual(assess_alert_flow(item)['admitted'],1)
        item['after']['post']['quota_admitted']['bytes'] += IP_BYTES
        with self.assertRaises(ValueError):assess_alert_flow(item)


class CallbackReceipts(unittest.TestCase):
    def example(self):
        return dict(sampled_ns=500,callbacks=[dict(nonce='ab'*16,name='eth0Alert',interface='eth0',
                    caller_uid=0,caller_pid=0,sequence=1,time_ns=300)])

    def test_actual_oneway_identity_and_global_rows_retained(self):
        value = self.example();value['callbacks'].append(dict(value['callbacks'][0],name='globalAlert',sequence=2,time_ns=400))
        self.assertEqual(len(receipts(value,'ab'*16)),1)
        self.assertEqual(len(value['callbacks']),2)

    def test_bad_identity_timing_and_order_rejected(self):
        for field,value in [('nonce','cd'*16),('name','fake'),('interface','eth1'),('caller_uid',1000),
                            ('caller_pid',123),('sequence',2),('time_ns',0),('time_ns',501)]:
            item = self.example();item['callbacks'][0][field] = value
            with self.subTest(field=field),self.assertRaises(ValueError):receipts(item,'ab'*16)
        item = self.example();item['callbacks'] *= 33
        with self.assertRaises(ValueError):receipts(item,'ab'*16)

    def test_quiet_windows_reject_unrelated_packets(self):
        item = flow();before = dict(packets=item['before']);after = copy.deepcopy(before)
        no_traffic(before,after)
        after['packets']['post']['quota_admitted']['bytes'] += 1
        with self.assertRaises(ValueError):no_traffic(before,after)
        after = copy.deepcopy(before);after['packets']['pre']['observed'][0]['other_ip_skbs'] += 1
        with self.assertRaises(ValueError):no_traffic(before,after)

    def test_inter_window_source_regression_is_not_hidden_by_registration(self):
        good = [(dict(map_id=1,bytes=100),dict(map_id=1,bytes=200)),
                (dict(map_id=1,bytes=200),dict(map_id=1,bytes=300))]
        ordered_usage(good,1)
        for row in (dict(map_id=1,bytes=199),dict(map_id=2,bytes=200)):
            bad = copy.deepcopy(good);bad[1] = (row,bad[1][1])
            with self.assertRaises(ValueError):ordered_usage(bad,1)


class OwnershipAndRestoration(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        with patch.dict(os.environ,ROYD_QUOTA_OUTPUT_DIR=str(Path(self.temp.name)/'trial')):
            self.trial = AlertTrial()

    def tearDown(self):self.temp.cleanup()

    def test_failed_arm_retains_cleanup_obligation(self):
        t = self.trial
        t.observe = lambda label:dict(state=dict(generation=0,bytes=0,armed=False,committed=0,error=0))
        def timeout(*args):raise TimeoutError('ambiguous Binder result')
        t.control = timeout
        with self.assertRaises(TimeoutError):t.arm('owned',100)
        self.assertTrue(t.alert_owned and t.restore_needed)

    def test_callback_request_checks_owner_before_rpc(self):
        t = self.trial
        def changed():raise ValueError('owner changed')
        t.owner = changed
        with self.assertRaisesRegex(ValueError,'owner changed'):t.callbacks()

    def test_late_extra_callback_rejected_before_controller_cleanup(self):
        t = self.trial;t.listening = True;t.manifest['WORKLOAD_STATUS'] = 'pass';t.nonce = 'ab'*16
        sample = CallbackReceipts().example()
        sample['callbacks'] += [dict(sample['callbacks'][0],sequence=2,time_ns=350),dict(sample['callbacks'][0],sequence=3,time_ns=400)]
        t.callbacks = lambda:sample
        with self.assertRaisesRegex(ValueError,'late interface callback'):t.before_close_controllers()

    def test_late_callback_failure_prevents_resource_deletion(self):
        t = self.trial;t.listening = True;t.manifest['WORKLOAD_STATUS'] = 'pass';t.nonce = 'ab'*16
        t.created = True;t.cid = 'owned';t.image = 'pinned';t.owner = lambda:None
        sample = CallbackReceipts().example()
        sample['callbacks'] += [dict(sample['callbacks'][0],sequence=2,time_ns=350),dict(sample['callbacks'][0],sequence=3,time_ns=400)]
        t.callbacks = lambda:sample;t.replay_packets = lambda:dict(status='pass')
        process = Mock();process.poll.return_value = 0
        t.controller_processes = [process];t.channels = {0:Mock()}
        calls = []
        def run(argv,*args,**kwargs):
            values = list(map(str,argv));calls.append(values)
            return subprocess.CompletedProcess(values,1 if values[:2] == ['docker','exec'] else 0,'')
        t.run = run;t.finish()
        self.assertFalse(any(v[:2] == ['docker','rm'] for v in calls))
        self.assertEqual(t.manifest['CONTROLLER_STATUS'],'not-tested')
        self.assertEqual(t.manifest['CAPTURE_STATUS'],'fail')

    def test_both_alert_stages_are_independently_required(self):
        for failed in ('ALERT_STATUS','ALERT_RESTORE_STATUS',None):
            with self.subTest(failed=failed),tempfile.TemporaryDirectory() as directory:
                with patch.dict(os.environ,ROYD_QUOTA_OUTPUT_DIR=str(Path(directory)/'trial')):
                    t = AlertTrial()
                for key in ('WORKLOAD_STATUS','RESTORE_STATUS','DETACH_STATUS','FIXTURE_STATUS','RUNTIME_STATUS',
                            'CAPTURE_STATUS','CLEANUP_STATUS','CONTROLLER_STATUS','ALERT_STATUS','ALERT_RESTORE_STATUS'):
                    t.manifest[key] = 'pass'
                if failed:t.manifest[failed] = 'fail'
                t.replay_packets = lambda:dict(status='pass');t.finish()
                self.assertEqual(t.manifest['RESULT_STATUS'],'fail' if failed else 'pass')

    def test_failed_alert_restoration_has_its_own_failed_stage(self):
        t = self.trial;t.alert_owned = True
        def failed(label):raise ValueError('alert state unavailable')
        t.state = failed
        with patch('run.Trial.finish',lambda self:None):t.finish()
        self.assertEqual(t.manifest['ALERT_RESTORE_STATUS'],'fail')
        self.assertTrue(t.failures)


if __name__ == '__main__':unittest.main()
