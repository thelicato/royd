"""Real finite-quota TCP recovery, segmentation and root/raw packet witnesses."""
import json,os,subprocess,time,threading,signal,sys
from pathlib import Path
from run import Trial,MAXIMUM,ROOT
from assess import need
from assess_transport import assess, assess_datagram

class TransportTrial(Trial):
    header_receive_buffer=4*1024*1024
    quota_inspect_mode='inspect-quota-alert'
    quota_observe_mode='observe-quota-alert'
    extra_required=('TCP_STATUS','UDP_SEGMENT_STATUS','RAW_STATUS','TRANSPORT_HEADERS_STATUS','TRANSPORT_CLEANUP_STATUS')

    def __init__(self):
        super().__init__()
        need(self.link is not None,'TCP quota gate requires the controlled isolated IPv4 link')
        self.manifest.update(ROYD_QUOTA_TCP_EVIDENCE_FORMAT=1,TCP_STATUS='not-tested',UDP_SEGMENT_STATUS='not-tested',RAW_STATUS='not-tested',TRANSPORT_HEADERS_STATUS='not-tested',TRANSPORT_CLEANUP_STATUS='not-tested')
        self.tcp_observers={};self.tcp_children=[];self.tcp_fixture=None;self.tcp_reader=None;self.tcp_lines=[];self.tcp_lock=threading.Lock()
        self.old_chains=None;self.transport_case=None;self.datagram_cases=[]
        self.transport_cleanup_ok=False

    def tcp_fixture_lines(self):
        with (self.out/'tcp-fixture.jsonl').open('x') as f:
            for raw in iter(self.tcp_fixture.stdout.readline,b''):
                f.write(raw.decode());f.flush()
                with self.tcp_lock:self.tcp_lines.append(json.loads(raw))

    def tcp_request(self,label):
        self.namespace_owner()
        answer={}
        for role,(process,directory,log) in self.tcp_observers.items():
            need(process.poll() is None,'TCP observer exited')
            temporary=directory/'request.tmp'
            with temporary.open('x') as f:f.write(label+'\n')
            os.link(temporary,directory/'request');temporary.unlink()
            self.wait(lambda:(directory/(label+'.json')).exists() or process.poll() is not None,5,'TCP snapshot')
            need(process.poll() is None,'TCP observer stopped during snapshot')
            answer[role]=json.loads((directory/(label+'.json')).read_text())
            need(answer[role]['query']==self.chains,'TCP source chain changed')
        return answer

    def prepare_tcp(self):
        self.link.owner('gateway');gateway=self.link.holders['gateway'];self.namespace_owner()
        self.dx(['sh','-ec','for n in tcp_retries1 tcp_retries2 tcp_syn_retries tcp_synack_retries tcp_thin_linear_timeouts; do printf "%s=" "$n"; cat "/proc/sys/net/ipv4/$n"; done'], 'tcp-kernel-policy.log')
        args=['nsenter','--net=/proc/'+str(gateway['pid'])+'/ns/net',str(self.out/'native/traffic'),'-mode','server','-listen','10.254.0.1:0','-tcp','-quota-fixture']
        self.tcp_fixture=subprocess.Popen(args,stdout=subprocess.PIPE,stderr=(self.out/'tcp-fixture.stderr').open('xb'))
        self.tcp_reader=threading.Thread(target=self.tcp_fixture_lines);self.tcp_reader.start()
        self.wait(lambda:bool(self.tcp_lines) or self.tcp_fixture.poll() is not None,5,'TCP fixture ready')
        need(self.tcp_fixture.poll() is None and self.tcp_lines[0]['event']=='ready','TCP fixture startup')
        fixture=self.tcp_lines[0];self.save('tcp-fixture-ready.json',dict(fixture,command=args,gateway_namespace=gateway['namespace']))
        self.run(['docker','cp',self.out/'native/traffic',self.cid+':'+self.android_dir+'/traffic'])
        self.dx(['chmod','755',self.android_dir+'/traffic'])
        self.old_chains=self.chains
        for role,mode in [('pre','observe-quota-pre'),('post','observe-quota-alert')]:
            directory=self.out/('tcp-observer-'+role);directory.mkdir();log=(self.out/('tcp-observer-'+role+'.log')).open('xb')
            args=['nsenter','--net=/proc/'+str(self.host_pid)+'/ns/net',str(self.out/'native/observe'),mode,self.bpf_root,self.namespace,str(self.out/'native/observe.bpf.o'),str(directory),fixture['address'].rsplit(':',1)[1],fixture['tcp_address'].rsplit(':',1)[1]]
            p=subprocess.Popen(args,stdout=log,stderr=subprocess.STDOUT);self.tcp_observers[role]=(p,directory,log)
            self.wait(lambda:(directory/'ready.json').exists() or p.poll() is not None,5,'TCP '+role+' observer')
            need(p.poll() is None,'TCP observer attachment')
        ready=json.loads((self.out/'tcp-observer-post/ready.json').read_text());self.chains=ready['query']
        for d in [0,1]:
            old=self.old_chains[d];new=self.chains[d]
            need(len(new)==len(set(new))==6 and len(old)==4,'TCP observer source cardinality')
            need(new[0]==old[0] and new[2]==old[1] and new[3]==old[2] and new[5]==old[3],'TCP observers replaced/reordered an existing link')
        return fixture

    def start_tcp_workers(self,fixture):
        cpus=sorted(os.sched_getaffinity(0));need(len(cpus)>=2,'Two allowed CPUs required for this controlled workload')
        workers=[]
        for uid,cpu in zip([0,1000],cpus[:2]):
            path=self.out/f'tcp-worker-{uid}.log';f=path.open('xb');args=['docker','exec','-i','--user',f'{uid}:{uid}',self.cid,'taskset',format(1<<cpu,'x'),self.android_dir+'/traffic','-tcp','-phase','7','-uid',str(uid),'-nonce',fixture['nonce'],'-address',fixture['tcp_address']]
            p=subprocess.Popen(args,stdin=subprocess.PIPE,stdout=f,stderr=subprocess.STDOUT);row=dict(uid=uid,pinned_cpu=cpu,path=path,process=p,log=f,command=args);self.tcp_children.append(row)
            self.wait(lambda:path.stat().st_size>0 or p.poll() is not None,5,'TCP worker ready')
            need(p.poll() is None,'TCP worker exited before barrier')
            data=[json.loads(x) for x in path.read_text().splitlines() if x.startswith('{')];need(len(data)==1 and data[0]['event']=='ready','TCP ready record');row['ready']=data[0]
            status=self.dx(['cat',f'/proc/{data[0]["pid"]}/status'],f'tcp-worker-{uid}-status.log')
            actual=next(l.split(':',1)[1].strip() for l in status.splitlines() if l.startswith('Cpus_allowed_list:'));need(actual==str(cpu),'TCP worker affinity not applied');row['actual_cpu_list']=actual
            need(data[0]['uid']==data[0]['gid']==uid and data[0]['pid']>1,'TCP worker credentials')
            if uid==1000:need(int(data[0]['cap_eff'],16)==0,'TCP native system worker retained capabilities')
            workers.append(row)
        return workers

    def workload(self):
        # The inherited permission, exact-fit, exhaustion, replacement and removal
        # matrix retains its original packet and noise assertions.
        super().workload()
        self.manifest['WORKLOAD_STATUS']='fail'
        # The ordinary-app matrix is complete. Its activity refresh must not
        # delay quota restoration during the bounded native socket workload.
        self.refresh_enabled=False
        fixture=self.prepare_tcp();workers=self.start_tcp_workers(fixture)
        self.set_quota('tcp-shared-budget',50000)
        before=self.tcp_request('tcp-before')
        self.transport_opened_realtime_ns=time.time_ns()
        opened_boottime_ns=time.clock_gettime_ns(time.CLOCK_BOOTTIME)
        self.save('tcp-start-boundary.json',dict(opened_realtime_ns=self.transport_opened_realtime_ns,opened_boottime_ns=opened_boottime_ns))
        for row in workers:row['process'].stdin.write(b'start\n');row['process'].stdin.flush()
        deadline=time.monotonic()+5;polls=[]
        while True:
            snapshot=self.tcp_request('tcp-exhaustion-'+str(len(polls)));polls.append(snapshot)
            if snapshot['post']['quota']['remaining']==0:break
            need(time.monotonic()<deadline,'TCP did not exhaust the shared finite allowance');time.sleep(.025)
        # Retain the first exhausted sample and the whole following denial window.
        held=polls[-1];time.sleep(.75);blocked=self.tcp_request('tcp-blocked')
        restoration=self.control('tcp-restore-unlimited','set',MAXIMUM)
        need(0<restoration['finished_ns']-opened_boottime_ns<=5_000_000_000,
             'Host orchestration exceeded the bounded TCP restoration window')
        restored=self.tcp_request('tcp-restored')
        completed=[]
        for row in workers:
            need(row['process'].wait(timeout=12)==0,'TCP transfer failed after restoration');row['log'].close()
            values=[json.loads(x) for x in row['path'].read_text().splitlines() if x.startswith('{')];need(len(values)==2 and values[-1]['event']=='tcp-complete','TCP completion record')
            completed.append(dict(values[-1],ready=row['ready'],pinned_cpu=row['pinned_cpu'],actual_cpu_list=row['actual_cpu_list'],command=row['command']))
        self.wait(lambda:sum(x.get('event')=='tcp-complete' for x in self.tcp_lines)==2,3,'TCP server completion receipts')
        time.sleep(.25);after=self.tcp_request('tcp-after')
        case=dict(limit=50000,fixture=fixture,workers=completed,server_receipts=[x for x in self.tcp_lines if x.get('event')=='tcp-complete'],before=before,held=held,blocked=blocked,restored=restored,after=after,exhaustion_samples=polls,opened_boottime_ns=opened_boottime_ns,restoration=restoration)
        self.save('tcp-case.json',case);result=assess(case);self.save('tcp-assessment.json',result);self.transport_case=case;self.manifest['TCP_STATUS']='pass'
        self.datagram_window(fixture,'segmented',9,1000,8)
        self.datagram_window(fixture,'raw',10,0,1)
        self.stop_tcp()
        self.save('transport-window.json',dict(opened_realtime_ns=self.transport_opened_realtime_ns,closed_realtime_ns=time.time_ns()))
        self.manifest['WORKLOAD_STATUS']='pass'

    def datagram_window(self,fixture,kind,phase,uid,step):
        path=self.out/('datagram-'+kind+'.log');log=path.open('xb')
        args=['docker','exec','-i','--user',f'{uid}:{uid}',self.cid,self.android_dir+'/traffic','-quota-crossing','-phase',str(phase),'-uid',str(uid),'-count',str(2*step),'-nonce',fixture['nonce'],'-address',fixture['address'],'-segmented' if kind=='segmented' else '-raw']
        p=subprocess.Popen(args,stdin=subprocess.PIPE,stdout=log,stderr=subprocess.STDOUT);row=dict(uid=uid,path=path,process=p,log=log,command=args);self.tcp_children.append(row)
        self.wait(lambda:path.stat().st_size>0 or p.poll() is not None,5,'Datagram worker ready');need(p.poll() is None,'Datagram worker exited before barrier')
        values=[json.loads(x) for x in path.read_text().splitlines() if x.startswith('{')];need(len(values)==1 and values[0]['event']=='ready','Datagram ready record');row['ready']=values[0]
        self.set_quota('datagram-'+kind+'-budget',2*step*1228+100)
        before=self.tcp_request('datagram-'+kind+'-before');p.stdin.write(b'start\n');p.stdin.flush()
        need(p.wait(timeout=9)==0,'Datagram crossing worker failed');log.close()
        values=[json.loads(x) for x in path.read_text().splitlines() if x.startswith('{')];need(len(values)==2,'Datagram typed receipt count')
        after=self.tcp_request('datagram-'+kind+'-after')
        case=dict(kind=kind,phase=phase,fixture=fixture,ready=row['ready'],worker=values[1],before=before,after=after,server_receipts=[x for x in self.tcp_lines if x.get('event')=='quota-udp-batch' and x.get('phase')==phase],command=args)
        self.save('datagram-'+kind+'-case.json',case);result=assess_datagram(case);self.save('datagram-'+kind+'-assessment.json',result);self.datagram_cases.append(case)
        self.manifest['UDP_SEGMENT_STATUS' if kind=='segmented' else 'RAW_STATUS']='pass'
        self.control('datagram-'+kind+'-restore','set',MAXIMUM)

    def stop_tcp(self):
        self.transport_cleanup_ok=False
        self.manifest['TRANSPORT_CLEANUP_STATUS']='fail'
        for row in self.tcp_children:
            if row['process'].poll() is None:
                # Closing our own barrier aborts a worker which has not started.
                # Started TCP workers retain their existing bounded socket deadlines.
                if row['process'].stdin is not None and not row['process'].stdin.closed:
                    row['process'].stdin.close()
                row['process'].wait(timeout=30)
            if row['process'].stdin is not None and not row['process'].stdin.closed:
                row['process'].stdin.close()
            row['log'].close()
        for process,directory,log in self.tcp_observers.values():
            if not (directory/'stop').exists():(directory/'stop').touch()
        for process,directory,log in self.tcp_observers.values():
            need(process.wait(timeout=10)==0,'TCP observer detach');log.close()
        if self.tcp_fixture is not None:
            if self.tcp_fixture.poll() is None:self.tcp_fixture.send_signal(signal.SIGTERM)
            need(self.tcp_fixture.wait(timeout=10)==143,'TCP fixture termination contract');self.tcp_reader.join(timeout=5);need(not self.tcp_reader.is_alive(),'TCP fixture ledger reader')
            rows=[x for x in self.tcp_lines if x.get('event')=='udp-fixture-stop'];need(len(rows)==1 and rows[0]['socket'].get('socket_drops')==0 and 'error' not in rows[0]['socket'],'TCP fixture socket/drop stop receipt')
        if self.old_chains is not None:self.chains=self.old_chains
        self.transport_cleanup_ok=True
        self.manifest['TRANSPORT_CLEANUP_STATUS']='pass'

    def before_owned_cleanup(self):
        need(self.transport_cleanup_ok,'Transport helper cleanup incomplete; preserve owned resources')

    def stop_headers(self):
        super().stop_headers()
        need(self.transport_case is not None and len(self.datagram_cases)==2,
             'Transport tuple/header acceptance requires all three completed cases')
        window=json.loads((self.out/'transport-window.json').read_text())
        tcp=json.loads((self.out/'tcp-case.json').read_text());datagrams=[json.loads((self.out/('datagram-'+kind+'-case.json')).read_text()) for kind in ['segmented','raw']]
        allowed=set()
        def add(protocol,local,remote):
            a,ap=local.rsplit(':',1);b,bp=remote.rsplit(':',1)
            allowed.add((protocol,a,int(ap),b,int(bp)));allowed.add((protocol,b,int(bp),a,int(ap)))
        for w in tcp['workers']:add(6,w['local'],w['remote'])
        for d in datagrams:add(17,d['worker']['local'],d['worker']['remote'])
        count=0
        for line in (self.header_directory/'headers.jsonl').open():
            row=json.loads(line)
            if not window['opened_realtime_ns']<=row['kernel_realtime_ns']<=window['closed_realtime_ns']:continue
            if row.get('family') not in (4,6):continue
            need(row['family']==4 and not row['fragmented'],'Non-IPv4/fragment traffic during transport window')
            key=(row['protocol'],row['source'],row.get('source_port'),row['destination'],row.get('destination_port'))
            need(key in allowed,'Unrelated IP in transport header window');count+=1
        need(count>0,'Transport header window empty')
        self.save('transport-header-assessment.json',dict(status='pass',packets=count,allowed_tuples=sorted(allowed),window=window,scope='Complete lossless header capture and broad kernel-realtime window. These bounds are not atomic policy-update timestamps.'))
        self.manifest['TRANSPORT_HEADERS_STATUS']='pass'

    def replay_packets(self):
        result=super().replay_packets();result['tcp']=assess(json.loads((self.out/'tcp-case.json').read_text()));result['datagrams']=[assess_datagram(json.loads((self.out/('datagram-'+kind+'-case.json')).read_text())) for kind in ['segmented','raw']];return result

    def finish(self):
        try:self.stop_tcp()
        except Exception:
            import traceback
            self.failures.append('TCP cleanup: '+traceback.format_exc())
        super().finish()


if __name__ == "__main__":
    from run import main
    sys.exit(main(TransportTrial))
