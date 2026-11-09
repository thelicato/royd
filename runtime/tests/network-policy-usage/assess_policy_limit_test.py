import copy
import importlib.util
from pathlib import Path
import sys
import unittest

QUOTA = Path(__file__).resolve().parents[1] / 'network-quota'
sys.path.insert(0, str(QUOTA))
from assess_policy_limit import assess, event_flow, IP_BYTES
from assess_policy_usage_test import case as usage_case

spec = importlib.util.spec_from_file_location('quota_packet_fixture', QUOTA / 'assess_test.py')
packets = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packets)


def case():
    old = usage_case()
    initial = old['before']
    first = copy.deepcopy(initial)
    final = copy.deepcopy(initial)
    for sample, generation, counters in ((first, 2, [11, 11228, 22, 22456]),
                                          (final, 4, [12, 12456, 23, 23684])):
        sample['pre']['counters'] = counters
        sample['post']['counters'] = counters
        sample['post']['quota'].update(generation=generation, limit=1, remaining=1)
        sample['post']['quota_admitted']['bytes'] += 2 * IP_BYTES
    query1 = dict(old['installed'], operation='inspect', sampled_ns=400,
                  recorded_bytes=86481 + 3 * IP_BYTES)
    query2 = dict(query1, sampled_ns=600, recorded_bytes=86481 + 5 * IP_BYTES)
    callbacks = [dict(sequence=i, nonce=old['nonce'], caller_uid=0, caller_pid=0,
                      interface='eth0', name='eth0', time_ns=t)
                 for i, t in ((1, 350), (2, 550))]
    live = dict(netd_alive=True, pid=1234, uid=0, deaths=0)
    return dict(nonce=old['nonce'], absolute_limit=old['absolute_limit'], baseline=old['baseline'],
                installed=old['installed'], initial=initial, first_auto=first, final_auto=final,
                first_inspect=query1, final_inspect=query2, callbacks=dict(callbacks=callbacks),
                listener_before=live, listener_after=copy.deepcopy(live), crossing_release_ns=300)


def crossing():
    item = packets.example()
    item.update(label='crossing-b-send')
    for name in ('before', 'after'):
        item[name]['post']['quota'].update(limit=2 * IP_BYTES + 100)
        item[name]['post']['quota_admitted'] = dict(map_id=60, bytes=1000)
    return item


class PolicyLimitAssessment(unittest.TestCase):
    def test_real_receipts_and_automatic_recorded_usage(self):
        result = assess(case())
        self.assertEqual(result['hard_limit_receipts'], 2)
        self.assertEqual(result['automatic_remaining'], 1)

    def test_explicit_poll_fake_receipts_regrant_noise_and_source_changes_fail(self):
        changes = [
            lambda x: x['first_inspect'].update(operation='poll'),
            lambda x: x['final_inspect'].update(recorded_bytes=86481),
            lambda x: x['first_inspect'].update(cycle_start_ms=11),
            lambda x: x['callbacks']['callbacks'].clear(),
            lambda x: x['callbacks']['callbacks'][0].update(name='globalAlert'),
            lambda x: x['callbacks']['callbacks'][0].update(caller_uid=1000),
            lambda x: x['callbacks']['callbacks'][0].update(time_ns=299),
            lambda x: x['callbacks']['callbacks'][1].update(sequence=1),
            lambda x: x['callbacks']['callbacks'][1].update(time_ns=601),
            lambda x: x['first_auto']['post']['quota'].update(limit=2556, remaining=2556),
            lambda x: x['final_auto']['post']['quota'].update(generation=2),
            lambda x: x['final_auto']['post']['quota'].update(contention=1),
            lambda x: x['final_auto']['post']['quota'].update(map_id=99),
            lambda x: x['final_auto']['post']['quota_admitted'].update(bytes=3457),
            lambda x: x['final_auto']['post'].update(counters=[12, 12457, 23, 23684]),
            lambda x: x['listener_after'].update(pid=1235),
            lambda x: x['listener_after'].update(deaths=1),
        ]
        for change in changes:
            value = case()
            change(value)
            with self.subTest(change=change), self.assertRaises(ValueError):
                assess(value)

    def test_crossing_allows_only_exhausted_old_or_derived_minimum_generation(self):
        for replacement in (False, True):
            value = crossing()
            if replacement:
                value['after']['post']['quota'].update(generation=21, limit=1, remaining=1)
            self.assertEqual(event_flow(value)['denied'], 1)

    def test_denial_does_not_accept_regrant_source_change_admission_or_noise(self):
        changes = [
            lambda x: x['after']['post']['quota'].update(generation=21, limit=2556, remaining=2556),
            lambda x: x['after']['post']['quota'].update(generation=19, limit=1, remaining=1),
            lambda x: x['after']['post']['quota'].update(remaining=1),
            lambda x: x['after']['post']['quota_admitted'].update(bytes=2228),
            lambda x: x['after']['post']['quota'].update(map_id=99),
            lambda x: x['after']['pre']['observed'][1].update(other_ip_skbs=1),
            lambda x: x['after']['post']['observed'][1].update(skbs=1),
        ]
        for change in changes:
            value = crossing()
            change(value)
            with self.subTest(change=change), self.assertRaises(ValueError):
                event_flow(value)


if __name__ == '__main__':
    unittest.main()
