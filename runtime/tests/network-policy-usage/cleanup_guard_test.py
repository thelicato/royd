import unittest
from policy_continuity import ContinuityTrial


def trial(native_exited=True,policy_touched=True,restored='pass'):
    value=ContinuityTrial.__new__(ContinuityTrial)
    value.burst_exited=native_exited
    value.policy_touched=policy_touched
    value.manifest={'POLICY_RESTORE_STATUS':restored}
    return value


class ContinuityCleanup(unittest.TestCase):
    def test_native_exit_does_not_authorise_deleting_an_unrestored_policy(self):
        with self.assertRaisesRegex(ValueError,'Unrestored policy requires retained resources'):
            trial(restored='fail').before_owned_cleanup()

    def test_native_process_must_still_be_confirmed_stopped(self):
        with self.assertRaisesRegex(ValueError,'Native helper not confirmed stopped'):
            trial(native_exited=False).before_owned_cleanup()

    def test_restored_or_untouched_policy_allows_owned_cleanup(self):
        trial().before_owned_cleanup()
        trial(policy_touched=False,restored='not-tested').before_owned_cleanup()


if __name__=='__main__':unittest.main()
