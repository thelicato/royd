"""Owned Android service recovery with native power and backend observations."""
import json
import os
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT/'runtime/tests/network-quota'))
from run import Trial, SCRIPTS, main
from assess_restart import assess


class ServiceRestartTrial(Trial):
    result_name = 'Network service restart'
    quota_inspect_mode = 'inspect-quota-alert'
    extra_required = ('SERVICE_RESTART_STATUS', 'NETWORK_STATE_STATUS', 'PERSISTENCE_STATUS', 'POWER_STATUS')

    def __init__(self):
        super().__init__()
        self.service = os.environ.get('ROYD_NETWORK_RESTART_SERVICE', 'netd')
        if self.service not in ('netd', 'zygote') or self.link is not None or self.headers_enabled:
            raise ValueError('This gate requires netd/zygote and the default bridge without packet observers')
        self.manifest.update(ROYD_NETWORK_RESTART_EVIDENCE_FORMAT=1, RESTART_SERVICE=self.service,
                             SERVICE_RESTART_STATUS='not-tested', NETWORK_STATE_STATUS='not-tested',
                             PERSISTENCE_STATUS='not-tested', POWER_STATUS='not-tested',
                             NETWORK_SCOPE='default-backend-service-recovery')
        self.recovered_identity = None

    def persistence(self, name):
        return self.dx(['sh', '-ec', '''
sha256sum /data/local/tmp/royd-service-restart
settings get global royd_service_restart
settings get secure android_id
cmd package list packages -U org.chromium.webview_shell
'''], name)

    def body(self):
        self.prepare_container()
        self.manifest.update(WORKLOAD_STATUS='fail', CONTROLLER_STATUS='pass', DETACH_STATUS='pass')
        self.dx(['sh', '-ec', r'''
printf '%s\n' "$1" > /data/local/tmp/royd-service-restart
settings put global royd_service_restart "$1"
attempt=0
until grep -Fq "$1" /data/system/users/0/settings_global.xml; do
  attempt=$((attempt+1)); [ "$attempt" -lt 10 ]; sleep 1
done
sync
''', 'sh', self.token], 'seed.log')
        before_persistence = self.persistence('persistence-before.log')
        before = dict(accounting=self.direct('backend-before-accounting.json'),
                      quota=self.direct('backend-before-quota.json', True))
        directory = self.out/'restart'
        directory.mkdir()
        self.manifest['SERVICE_RESTART_STATUS'] = self.manifest['POWER_STATUS'] = 'fail'
        self.run([SCRIPTS/'framework-restart.sh', self.cid, directory, '180', self.service],
                 'restart.log', timeout=420,
                 env=dict(os.environ, ROYD_RESTART_ASSERT_RUNNER=str(SCRIPTS/'assert-runtime.sh'),
                          ROYD_HAL_PROFILE='graphical', ROYD_GRAPHICS_BACKEND='software',
                          ROYD_RESOURCE_PROFILE='low-memory'))
        self.manifest['SERVICE_RESTART_STATUS'] = self.manifest['POWER_STATUS'] = 'pass'
        current = self.identity('identity-recovered.json')
        after = dict(accounting=self.direct('backend-after-accounting.json'),
                     quota=self.direct('backend-after-quota.json', True))
        case = dict(service=self.service, identity_before=self.initial_identity, identity_after=current,
                    host_init_before=self.host_pid, host_init_after=self.owner()['State']['Pid'],
                    before=before, after=after, token=self.token, persistence_before=before_persistence,
                    persistence_after=self.persistence('persistence-after.log'))
        self.save('restart-case.json', case)
        result = assess(case)
        self.save('restart-assessment.json', result)
        self.recovered_identity = current
        self.manifest.update(WORKLOAD_STATUS='pass', NETWORK_STATE_STATUS='pass', PERSISTENCE_STATUS='pass')

    def replay_packets(self):
        return assess(json.loads((self.out/'restart-case.json').read_text()))

    def validate_runtime_identity(self, current):
        if self.recovered_identity is None or current != self.recovered_identity:
            raise ValueError('Unexpected Android/Docker replacement after the explicit recovery')


if __name__ == '__main__':
    sys.exit(main(ServiceRestartTrial))
