"""Explicit netd-owned alert lifetime and fresh-client packet acceptance."""
import json
import os
import sys

from service_restart import ServiceRestartTrial
from assess_restart import assess as assess_backend
from interface_alert import AlertTrial, receipts
from run import MAXIMUM, main
from assess import need


def assess_ownership(case):
    before, after = case['listener_before'], case['listener_after']
    need(before['sampled_ns'] > 0 and before == dict(pid=case['client_pid'], uid=0,
         netd_alive=True, deaths=0, death_ns=0, sampled_ns=before['sampled_ns']),
         'Missing original live listener identity')
    need(after == dict(before, netd_alive=False, deaths=1, death_ns=after['death_ns'],
         sampled_ns=after['sampled_ns'])
         and before['sampled_ns'] < after['death_ns'] <= after['sampled_ns'],
         'Missing exact old-service Binder death receipt')
    a, b = case['state_before'], case['state_after']
    need(a == dict(generation=1, bytes=MAXIMUM, armed=True, committed=0, error=0),
         'Original associated alert was not armed')
    need(b == dict(generation=0, bytes=0, armed=False, committed=0, error=0),
         'New netd retained a stale associated registration')
    need(not receipts(case['callbacks_before'], case['nonce'])
         and not receipts(case['callbacks_after'], case['nonce']),
         'Unexpected callback from the large pre-restart threshold')
    return dict(status='pass', scope='Netd-owned registration loss and old Binder death; fresh-client acceptance is separate')


class AlertRestartTrial(AlertTrial):
    result_name = 'Associated-alert service restart'
    extra_required = AlertTrial.extra_required + ServiceRestartTrial.extra_required + ('ALERT_OWNERSHIP_STATUS',)
    persistence = ServiceRestartTrial.persistence
    validate_runtime_identity = ServiceRestartTrial.validate_runtime_identity

    def __init__(self):
        super().__init__()
        self.service = os.environ.get('ROYD_NETWORK_RESTART_SERVICE', 'netd')
        need(self.service in ('netd', 'zygote') and self.link is not None,
             'Alert restart gate requires netd/zygote and the controlled IPv4 link')
        self.recovered_identity = None
        self.manifest.update(ROYD_NETWORK_RESTART_EVIDENCE_FORMAT=1, RESTART_SERVICE=self.service,
                             SERVICE_RESTART_STATUS='not-tested', NETWORK_STATE_STATUS='not-tested',
                             PERSISTENCE_STATUS='not-tested', POWER_STATUS='not-tested',
                             ALERT_OWNERSHIP_STATUS='not-tested')

    def prepare_container(self):
        super().prepare_container()
        self.manifest['ALERT_OWNERSHIP_STATUS'] = 'fail'
        channel = self.start_controller(0, 'controller-before-restart')
        need(channel.request('listen') == dict(listening=True), 'Original listener registration')
        self.listening = True
        listener_before = channel.request('listener-status')
        callbacks_before = self.callbacks()
        self.alert_owned = self.restore_needed = True
        self.control('pre-restart-arm', 'set-alert', MAXIMUM)
        state_before = self.state('pre-restart-alert')
        ServiceRestartTrial.restart_backend(self)
        self.manifest['WORKLOAD_STATUS'] = 'fail'
        case = dict(client_pid=channel.hello['pid'], nonce=self.nonce,
                    listener_before=listener_before, listener_after=channel.request('listener-status'),
                    state_before=state_before, state_after=self.state('recovered-alert'),
                    callbacks_before=callbacks_before, callbacks_after=self.callbacks())
        self.save('alert-ownership-case.json', case)
        self.save('alert-ownership-assessment.json', assess_ownership(case))
        # Do not carry a dead registration through the passive preparation window.
        # Retain this closed channel for the original completeness/cleanup checks.
        channel.close()
        self.channels['before-restart'] = self.channels.pop(0)
        self.listening = False
        self.manifest['ALERT_OWNERSHIP_STATUS'] = 'pass'

    def replay_packets(self):
        backend = assess_backend(json.loads((self.out/'restart-case.json').read_text()))
        ownership = assess_ownership(json.loads((self.out/'alert-ownership-case.json').read_text()))
        old = self.channels['before-restart'].hello['pid']
        need(self.channels[0].hello['pid'] != old, 'Fresh listener client identity was reused')
        return dict(backend=backend, ownership=ownership, matrix=super().replay_packets())


if __name__ == '__main__':
    sys.exit(main(AlertRestartTrial))
