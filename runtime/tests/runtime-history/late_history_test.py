"""Exercise actual runtime assertions with failures first recorded by their workload."""
from pathlib import Path
import os,subprocess,tempfile,unittest

ROOT=Path(__file__).resolve().parents[3]
SCRIPTS=ROOT/'runtime/scripts'
PAYLOADS={
 'cgroup':'libprocessgroup: SetCgroup::ExecuteForProcess: failed to open /dev/cpuctl/top-app/cgroup.procs: No such file or directory',
 'metadata':'ResilientAtomicFile: Failed to verity-protect package manager settings',
 'ART':"ArtService: Fstab entries not found for '/system/priv-app/Settings/Settings.apk'",
 'watchdog':'Watchdog: WAITED_UNTIL_PRE_WATCHDOG',
 'watchdog-subject':'Watchdog: ROYD: pre-watchdog blocked checkers: Blocked in handler on main thread (main) for 15s',
 'watchdog-timing':'Watchdog: ROYD: pre-watchdog checker timing: name=main thread start_uptime_ms=12345 sampled_uptime_ms=27582 elapsed_ms=15237 wait_max_ms=60000',
 'watchdog-control':'Watchdog: checker timing is reported only during a pre-watchdog event',
 'SysRq':'Watchdog: Failed to write to /proc/sysrq-trigger',
 'recovered-crash':'am_crash: [0,1365,com.android.settings,0,java.lang.NullPointerException,example]\nActivityManager: Start proc 202:com.android.settings/u0a55 for top-activity',
 'historic-audio':'10-15 12:16:03.184 111 309 W ServiceManagerCppClient: Waited one second for activity (is service started?)\n10-15 12:16:04.000 111 222 D audioserver: ordinary diagnostic',
 'ANR':'I am_anr  : [0,101,example.app,0,Input dispatching timed out]',
 'media-control':'ModernMediaScanner: Failed to visit /oem/media: NoSuchFileException',
 'binder-control':'Binder: Outgoing transactions from this process must be FLAG_ONEWAY\nBinder: at android.content.ContentProviderProxy.openTypedAssetFile(ContentProviderNative.java:812)',
 'display':"HwcComposer: getDisplayIdentificationData failed Status(-8, EX_SERVICE_SPECIFIC): '8:",
 'density':'SurfaceFlinger: ro.sf.lcd_density must be defined as a build property',
}


class LateHistory(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='royd-history-contract-')
        self.addCleanup(self.temp.cleanup);self.out=Path(self.temp.name);self.bin=self.out/'bin';self.bin.mkdir()
        source=(SCRIPTS/'assert-runtime-contract-test.sh').read_text()
        mock=source.split('cat > "$tmp/docker" <<\'MOCK\'\n',1)[1].split('\nMOCK\n',1)[0]
        for phase,label in [('connected','connected-devices'),('capture','video')]:
            needle='        *royd-runtime-'+label+'-test*)\n';assert mock.count(needle)==1
            mock=mock.replace(needle,needle+'          if [ "${HISTORY_PHASE:-}" = '+phase+' ]; then : >"$HISTORY_STATE"; fi\n')
        needle='  logs)\n';assert mock.count(needle)==1
        mock=mock.replace(needle,needle+'    if [ -f "${HISTORY_STATE:-/nonexistent}" ]; then cat "$HISTORY_PAYLOAD"; fi\n')
        path=self.bin/'docker';path.write_text(mock+'\n');path.chmod(0o755)

    def run_case(self,payload,phase='capture',*,helper=False,backend='software',hal='graphical',read_failure=False):
        state=self.out/'state';state.unlink(missing_ok=True)
        data=self.out/'payload';data.write_text(payload+'\n')
        if helper:state.touch()
        env={k:v for k,v in os.environ.items() if not k.startswith('MOCK_')}
        env.update(PATH=str(self.bin)+os.pathsep+os.environ['PATH'],MOCK_SDK='35',HISTORY_PHASE=phase,
            HISTORY_STATE=str(state),HISTORY_PAYLOAD=str(data))
        if read_failure:env['MOCK_APP_ANR_LOG_FAILURE']='1'
        script=SCRIPTS/('assert-android15-log-history.sh' if helper else 'assert-runtime.sh')
        args=[str(script),'history-contract']+([backend,hal] if helper else [])
        p=subprocess.run(args,env=env,capture_output=True,text=True,timeout=30)
        if not helper:self.assertTrue(state.exists(),'The production workload must reach the failure injection phase: '+p.stderr)
        return p

    def test_workload_failures_are_rejected_even_after_recovery(self):
        for phase in ('connected','capture'):
            for name in ('cgroup','metadata','ART','watchdog','watchdog-subject','watchdog-timing','SysRq','recovered-crash','historic-audio','ANR'):
                with self.subTest(phase=phase,name=name):
                    result=self.run_case(PAYLOADS[name],phase)
                    self.assertNotEqual(result.returncode,0,result.stdout)
                    self.assertNotIn('Runtime checks passed:',result.stdout)

    def test_unrelated_late_diagnostics_remain_visible_and_allowed(self):
        for name in ('media-control','binder-control','watchdog-control'):
            with self.subTest(name=name):
                result=self.run_case(PAYLOADS[name]);self.assertEqual(result.returncode,0,result.stderr)
                self.assertIn('Runtime checks passed:',result.stdout)

    def test_existing_renderer_and_hal_scopes_are_preserved(self):
        for name,backend,hal,rejected in [
            ('display','software','graphical',True),('display','host-gpu-generic','graphical',False),
            ('density','software','graphical',True),('density','software','headless',False)]:
            with self.subTest(name=name,backend=backend,hal=hal):
                result=self.run_case(PAYLOADS[name],helper=True,backend=backend,hal=hal)
                self.assertEqual(result.returncode!=0,rejected,result.stderr)

    def test_partial_failed_log_read_is_never_a_healthy_snapshot(self):
        result=self.run_case('',helper=True,read_failure=True)
        self.assertNotEqual(result.returncode,0)
        self.assertIn('could not read Android 15 runtime failure history',result.stderr)


if __name__=='__main__':unittest.main()
