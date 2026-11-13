"""Real associated-alert replacement during framework-owned quota exhaustion."""
from pathlib import Path
import errno,json,re,sys,time
ROOT=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(ROOT/'runtime/tests/network-quota'))
from policy_continuity import ContinuityTrial
from run import main
from assess import need
from assess_policy_concurrent import target,associated,assess


class ConcurrentTrial(ContinuityTrial):
    result_name='Concurrent framework quota and associated alert'
    extra_required=ContinuityTrial.extra_required+('ASSOCIATED_STATUS','ASSOCIATED_RESTORE_STATUS')
    def __init__(self):
        super().__init__();self.alert_owned=False;self.events={};self.rearmed=False
        self.manifest.update(ROYD_POLICY_CONCURRENT_EVIDENCE_FORMAT=1,ASSOCIATED_STATUS='not-tested',ASSOCIATED_RESTORE_STATUS='not-tested')

    def alert_state(self,label):
        text=self.dx(['timeout','10','dumpsys','netd'],label+'.log')
        rows=re.findall(r'^royd interface alert: generation=(\d+) bytes=(\d+) armed=(yes|no) committed=(\d+) error=(\d+) sample_ms=250$',text,re.M)
        need(len(rows)==1,'Associated dump unavailable/ambiguous');g,b,a,c,e=rows[0]
        return dict(generation=int(g),bytes=int(b),armed=a=='yes',committed=int(c),error=int(e))

    def before_stream(self):
        self.manifest['ASSOCIATED_STATUS']='fail'
        self.refresh_workers()
        before=self.snapshot('associated-arm-before');a=self.alert_state('associated-arm-before')
        need(a==dict(generation=0,bytes=0,armed=False,committed=0,error=0),'Pre-existing associated alert')
        self.alert_owned=True
        receipt=self.control('associated-arm','set-alert',1228)
        state=self.alert_state('associated-arm-after');after=self.snapshot('associated-arm-after')
        self.events['arm']=dict(before=before,before_state=a,receipt=receipt,after=after,after_state=state)
        self.save('associated-arm.json',self.events['arm'])
        # The ordinary baseline is complete. Keep UI launches outside this
        # bounded native-only interval so they cannot delay live replacement.
        self.refresh_enabled=False

    def during_stream(self):
        callbacks=self.channels[0].request('callbacks')
        rows=target(callbacks,self.nonce)
        if rows and not self.rearmed:
            need(len(rows)==1 and self.burst_process.poll() is None,'Associated receipt outside the live stream')
            before=self.snapshot('associated-rearm-before');state=self.alert_state('associated-rearm-before')
            start=time.monotonic_ns();receipt=self.control('associated-rearm','set-alert',1228);end=time.monotonic_ns()
            need(self.burst_process.poll() is None,'Replacement did not finish during stream')
            after_state=self.alert_state('associated-rearm-after');after=self.snapshot('associated-rearm-after')
            self.events['rearm']=dict(before=before,before_state=state,receipt=receipt,after=after,
                after_state=after_state,start_ns=start,end_ns=end,callbacks=callbacks)
            self.save('associated-rearm.json',self.events['rearm']);self.rearmed=True

    def after_stream(self):
        need(self.rearmed,'No observed live associated replacement')
        before=self.snapshot('associated-quiet-before');state=self.alert_state('associated-quiet-before')
        callbacks=self.channels[0].request('callbacks');start=time.monotonic_ns();time.sleep(1);end=time.monotonic_ns()
        after=self.snapshot('associated-quiet-after');after_state=self.alert_state('associated-quiet-after')
        later=self.channels[0].request('callbacks')
        self.events['quiet']=dict(before=before,before_state=state,after=after,after_state=after_state,
            callbacks_before=callbacks,callbacks_after=later,start_ns=start,end_ns=end)
        self.save('associated-quiet.json',self.events['quiet'])

    def decorate_case(self,case):
        case['associated']=self.events
        result=associated(case);self.save('associated-assessment.json',result)
        self.manifest['ASSOCIATED_STATUS']='pass'

    def assess_case(self,case,receipts):return assess(case,receipts)

    def replay_packets(self):
        packet=super().replay_packets();case=json.loads((self.out/'continuity-case.json').read_text())
        for key in ('arm','rearm','quiet'):
            need(case['associated'][key]==json.loads((self.out/('associated-'+key+'.json')).read_text()),'Saved associated event differs')
        return packet

    def finish(self):
        self.finishing=True;self.refresh_enabled=False
        self.attempt('complete native stream before alert restoration',self.stop_burst)
        if self.alert_owned:
            self.manifest['ASSOCIATED_RESTORE_STATUS']='fail'
            def restore():
                before=self.snapshot('associated-restore-before') if self.manifest['WORKLOAD_STATUS']=='pass' else None
                state=self.alert_state('associated-restore-before')
                self.control('associated-restore','remove-alert',expected=0 if state['bytes'] else errno.ENOENT)
                after=self.alert_state('associated-restore-after')
                packets=self.snapshot('associated-restore-after') if before is not None else None
                for sample in ((before,packets) if before is not None else ()):
                    q=sample['post']['quota']
                    need(q['present'] and q['limit']==q['remaining']==1 and q['invalid']==q['contention']==0,
                         'Alert cancellation removed or regranted the exhausted policy')
                need(before is None or before['post']['quota_admitted']==packets['post']['quota_admitted'],
                     'Admitted source changed during cancellation')
                need(after['bytes']==0 and not after['armed'] and after['error']==0,'Associated alert restoration failed')
                self.manifest['ASSOCIATED_RESTORE_STATUS']='pass'
            self.attempt('restore originally absent associated alert',restore)
        else:self.manifest['ASSOCIATED_RESTORE_STATUS']='pass'
        super().finish()

    def before_owned_cleanup(self):
        need(self.manifest['ASSOCIATED_RESTORE_STATUS']=='pass','Unrestored associated alert requires retained resources')
        super().before_owned_cleanup()

if __name__=='__main__':sys.exit(main(ConcurrentTrial))
