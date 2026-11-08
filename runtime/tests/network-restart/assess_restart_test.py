import copy
import unittest
from types import SimpleNamespace
from assess_restart import assess, MAXIMUM
from service_restart import ServiceRestartTrial
from run import Trial


def case(service='netd'):
    acc = dict(ifindex=2, map_id=100, counters=[10, 1000, 20, 2000],
               production_links=[31, 32], query=[[31, 41], [32, 42]])
    quota = dict(acc, production_links=[41, 42],
                 quota=dict(map_id=200, drops_map_id=201, present=True, limit=MAXIMUM,
                            remaining=MAXIMUM-100, generation=5, invalid=0, contention=0),
                 quota_admitted=dict(map_id=202, bytes=100))
    before = dict(accounting=copy.deepcopy(acc), quota=copy.deepcopy(quota))
    after = copy.deepcopy(before)
    for role in after:
        after[role]['counters'] = [13, 1300, 24, 2400]
    after['quota']['quota'].update(generation=6, remaining=MAXIMUM-200)
    after['quota']['quota_admitted']['bytes'] = 800
    identity = dict(id='owned', started='start', restart_count=0, oom=False, running=True,
                    system_server='500', netd='200')
    persistence = '0'*64+'  /data/local/tmp/royd-service-restart\nnonce\na03aad489ae0bca\npackage:org.chromium.webview_shell uid:10054\n'
    return dict(service=service, before=before, after=after, identity_before=identity,
                identity_after=dict(identity, system_server='1000', netd='900'),
                host_init_before=700, host_init_after=700, token='nonce',
                persistence_before=persistence, persistence_after=persistence)


class BackendRecovery(unittest.TestCase):
    def test_both_service_lifetimes_with_new_quota_registration(self):
        for service in ('netd', 'zygote'):
            result = assess(case(service))
            self.assertEqual(result['status'], 'pass')
            self.assertEqual(result['interface_deltas']['accounting'], [3, 300, 4, 400])
            self.assertEqual(result['admitted_delta'], 700)
            self.assertTrue(result['quota_reregistered'])

    def test_replacement_reset_missing_identity_and_ownership_cannot_pass(self):
        mutations = [
            lambda x:x['identity_after'].update(started='restarted'),
            lambda x:x['identity_after'].update(system_server='500'),
            lambda x:x['identity_after'].update(netd='200'),
            lambda x:x['identity_after'].update(netd='900 901'),
            lambda x:x.update(host_init_after=701),
            lambda x:x['after']['accounting'].update(map_id=999),
            lambda x:x['after']['accounting']['counters'].__setitem__(0, 0),
            lambda x:x['after']['quota']['quota'].update(map_id=999),
            lambda x:x['after']['quota']['quota'].update(generation=4),
            lambda x:x['after']['quota']['quota'].update(contention=1),
            lambda x:x['after']['quota']['quota_admitted'].update(bytes=0),
            lambda x:x.update(persistence_after=x['persistence_after'].replace('nonce', 'other')),
        ]
        for mutate in mutations:
            value = case();mutate(value)
            with self.subTest(mutation=mutate), self.assertRaises(ValueError):assess(value)
        value = case('zygote');value['identity_after']['netd']='200'
        with self.assertRaises(ValueError):assess(value)

    def test_same_generation_cannot_gain_allowance(self):
        value = case();value['after']['quota']['quota'].update(generation=5, remaining=MAXIMUM-50)
        with self.assertRaises(ValueError):assess(value)
        value['after']['quota']['quota']['remaining']=MAXIMUM-200
        self.assertFalse(assess(value)['quota_reregistered'])

    def test_default_identity_check_and_explicit_recovery_both_reject_later_replacement(self):
        value = case()
        default = SimpleNamespace(initial_identity=value['identity_before'])
        Trial.validate_runtime_identity(default, value['identity_before'])
        with self.assertRaises(ValueError):Trial.validate_runtime_identity(default, value['identity_after'])
        trial = object.__new__(ServiceRestartTrial)
        trial.recovered_identity = None
        with self.assertRaises(ValueError):trial.validate_runtime_identity(value['identity_after'])
        trial.recovered_identity = value['identity_after']
        trial.validate_runtime_identity(value['identity_after'])
        with self.assertRaises(ValueError):trial.validate_runtime_identity(dict(value['identity_after'], netd='1001'))


if __name__ == '__main__':
    unittest.main()
