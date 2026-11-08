import copy
import unittest
from alert_restart import assess_ownership
from run import MAXIMUM


def case():
    return dict(client_pid=700, nonce='a'*32,
                listener_before=dict(pid=700, uid=0, netd_alive=True, deaths=0, death_ns=0, sampled_ns=100),
                listener_after=dict(pid=700, uid=0, netd_alive=False, deaths=1, death_ns=150, sampled_ns=200),
                state_before=dict(generation=1, bytes=MAXIMUM, armed=True, committed=0, error=0),
                state_after=dict(generation=0, bytes=0, armed=False, committed=0, error=0),
                callbacks_before=dict(callbacks=[], sampled_ns=100),
                callbacks_after=dict(callbacks=[], sampled_ns=200))


class RegistrationOwnership(unittest.TestCase):
    def test_dead_service_with_empty_new_registration(self):
        self.assertEqual(assess_ownership(case())['status'], 'pass')

    def test_live_old_service_stale_registration_and_callback_cannot_pass(self):
        value = case()
        mutations = [
            lambda x:x['listener_after'].update(netd_alive=True),
            lambda x:x['listener_after'].update(pid=701),
            lambda x:x['listener_after'].update(deaths=0),
            lambda x:x['listener_after'].update(death_ns=99),
            lambda x:x['state_before'].update(armed=False),
            lambda x:x['state_after'].update(generation=1),
            lambda x:x['state_after'].update(error=5),
            lambda x:x['callbacks_after']['callbacks'].append(dict(nonce='a'*32,
                sequence=1, caller_uid=0, caller_pid=0, interface='eth0',
                name='eth0Alert', time_ns=150)),
        ]
        for mutate in mutations:
            changed = copy.deepcopy(value)
            mutate(changed)
            with self.subTest(mutation=mutate), self.assertRaises(ValueError):
                assess_ownership(changed)


if __name__ == '__main__':
    unittest.main()
