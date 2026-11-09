"""Execute the actual quota calculation/dispatch before and after usage readiness."""
from pathlib import Path
import os,shutil,subprocess,sys,tempfile
root=Path(sys.argv[1]).resolve();sys.path.insert(0,str(root/'android/tests/fixtures/android15'))
from SettingsSearchPatchFixture import sources,method
path='frameworks/base/services/core/java/com/android/server/net/NetworkPolicyManagerService.java'
patch=root/'android/patches/android-15.0.0_r36/0090-services-bound-oci-quota-before-usage-readiness.patch'
a=sources(patch,prefixes=('frameworks/base/',))[path]
b=sources(patch,after=True,prefixes=('frameworks/base/',))[path]
def calculation(text):
    return text[text.index('            final boolean hasWarning ='):text.index('            // keep track of lowest')]
def block(text,needle):
    start=text.index(needle);brace=text.index('{',start);depth=1
    for end in range(brace+1,len(text)):
        depth+=(text[end]=='{')-(text[end]=='}')
        if not depth:return text[start:end+1]
    raise AssertionError(needle)
gate=method(b,'shouldObserveRoydEthernetStats');helper=method(b,'roydInterfaceQuotaLimit')
query=method(b,'getTotalBytes');assert query==method(a,'getTotalBytes')
dump_start=b.rfind('if (mObserveRoydEthernetStats)',0,b.index('royd Ethernet quota readiness:'))
dump=block(b[dump_start:],'if (mObserveRoydEthernetStats)')
actual=os.environ.get('ROYD_ANDROID15_QUOTA_READINESS_SOURCE')
if actual:
    source=(Path(actual)/path).read_text()
    for text in (calculation(b),helper,query,gate,dump):assert text.strip() in source
    assert '@GuardedBy("mNetworkPoliciesSecondLock")\n    private boolean mRoydQuotaUsageWaitReported;' in source
jdk=os.environ.get('ROYD_TEST_JAVA_HOME');candidate=root/'.work/android-src-15/prebuilts/jdk/jdk21/linux-x86'
if not jdk and (candidate/'bin/javac').is_file():jdk=str(candidate)
javac=str(Path(jdk)/'bin/javac') if jdk else shutil.which('javac');java=str(Path(jdk)/'bin/java') if jdk else shutil.which('java')
if not javac or not java:print('Java execution skipped: set ROYD_TEST_JAVA_HOME for quota readiness contracts');raise SystemExit(0)
common=r'''
import java.util.*;import java.io.*;import java.time.*;
class Pair<A,B>{final A first;final B second;Pair(A a,B b){first=a;second=b;}}
class NetworkTemplate {static final int MATCH_ETHERNET=5;int rule=5;int getMatchRule(){return rule;}}
class NetworkPolicy {
 NetworkTemplate template=new NetworkTemplate();long warningBytes=-1,limitBytes=8473137,lastWarningSnooze=-1,lastLimitSnooze=-1;
 boolean cycle=true,metered=true;boolean hasCycle(){return cycle;}boolean isOverWarning(long total){return total>=warningBytes;}
}
class NetworkPolicyManager {
 static Iterator<Pair<ZonedDateTime,ZonedDateTime>> cycleIterator(NetworkPolicy p){return List.of(new Pair<>(ZonedDateTime.parse("2026-11-01T00:00Z"),ZonedDateTime.parse("2026-12-01T00:00Z"))).iterator();}
}
class ArraySet<T> extends ArrayList<T>{T valueAt(int i){return get(i);}}
class Stats {boolean ready;int reads,flipAfterReads;boolean isAnyCallbackReceived(){boolean r=ready;if(++reads==flipAfterReads)ready=true;return r;}}
class Deps {int queries;boolean failure;long used=84529;long getNetworkTotalBytes(NetworkTemplate t,long start,long end){queries++;if(failure)throw new IllegalStateException("query failure");return used;}}
class Slog {static int logs;static void i(String tag,String message){if(!message.equals("ROYD: holding OCI Ethernet quotas at one byte until usage is ready"))throw new AssertionError(message);logs++;}static void w(String t,String m){}}
'''
def source(name,text):
    return 'class '+name+' {\n'+r'''
 static final long LIMIT_DISABLED=-1;static final String TAG="NetworkPolicy";
 final Object mNetworkPoliciesSecondLock=new Object();final boolean mObserveRoydEthernetStats=shouldObserveRoydEthernetStats();
 boolean mRoydQuotaUsageWaitReported;Stats mStatsCallback=new Stats();Deps mDeps=new Deps();
 final Map<String,long[]> installed=new HashMap<>();boolean sinkFailure;
 void setInterfaceQuotasAsync(String iface,long warning,long limit){if(!Thread.holdsLock(mNetworkPoliciesSecondLock))throw new AssertionError("lost lock");if(sinkFailure)throw new IllegalArgumentException("sink failure");installed.put(iface,new long[]{warning,limit});}
'''+gate+'\n'+helper+'\n'+query+r'''
 void calculate(NetworkPolicy policy,String...ifaces){synchronized(mNetworkPoliciesSecondLock){ArraySet<String>matchingIfaces=new ArraySet<>();matchingIfaces.addAll(List.of(ifaces));Set<String>newMeteredIfaces=new HashSet<>();
'''+calculation(text)+r'''
 }}
 String state(){StringWriter s=new StringWriter();PrintWriter fout=new PrintWriter(s);synchronized(mNetworkPoliciesSecondLock){
'''+dump+r'''}fout.flush();return s.toString();}
}
'''
harness=r'''
public class Harness {
 static void need(boolean v){if(!v)throw new AssertionError();}
 static void clean(){Slog.logs=0;}
 static NetworkPolicy policy(){return new NetworkPolicy();}
 public static void main(String[]args){
  android.system.Os.error=Integer.parseInt(args[0]);boolean gated=Boolean.parseBoolean(args[1]);
  Source s=new Source();need(s.mObserveRoydEthernetStats==gated);NetworkPolicy p=policy();
  clean();s.calculate(p,"eth0","eth1");need(s.installed.get("eth0")[1]==(gated?1:8473137)&&s.installed.get("eth1")[1]==8473137&&s.mDeps.queries==0&&Slog.logs==(gated?1:0));
  s.calculate(p,"eth0");need(Slog.logs==(gated?1:0));
  need(s.state().equals(gated?"royd Ethernet quota readiness: received=no conservative_used=yes\n":""));
  // A real readiness transition resumes ordinary recorded-usage calculation.
  s.mStatsCallback.ready=true;s.calculate(p,"eth0");need(s.installed.get("eth0")[1]==8388608&&s.mDeps.queries==1);
  need(s.state().equals(gated?"royd Ethernet quota readiness: received=yes conservative_used=yes\n":""));
  s.mDeps.used=9000000;s.calculate(p,"eth0");need(s.installed.get("eth0")[1]==1);
  // The unchanged guard never queries while unready. Preserve that guard's failure.
  s=new Source();s.mDeps.failure=true;s.calculate(p,"eth0");need(s.mDeps.queries==0);
  s.mStatsCallback.ready=true;try{s.calculate(p,"eth0");throw new AssertionError();}catch(IllegalStateException wanted){need(wanted.getMessage().equals("query failure"));}
  // Callback publication can race after a query has returned its unready zero.
  clean();s=new Source();s.mStatsCallback.flipAfterReads=gated?2:1;s.calculate(policy(),"eth0");
  need(s.mStatsCallback.ready&&s.mDeps.queries==0&&s.installed.get("eth0")[1]==(gated?1:8473137));
  s.calculate(policy(),"eth0");need(s.installed.get("eth0")[1]==8388608);
  // No limit, no cycle, snoozed limits and other templates keep stock behaviour.
  for(int control=0;control<5;control++){
   clean();s=new Source();p=policy();
   if(control==0)p.limitBytes=-1;
   if(control==1)p.cycle=false;
   if(control==2)p.lastLimitSnooze=Long.MAX_VALUE;
   if(control==3)p.template.rule=4;
   if(control==4){p.limitBytes=-1;p.warningBytes=1000;}
   s.calculate(p,"eth0");need(s.installed.get("eth0")[1]==(control==3?8473137:Long.MAX_VALUE)&&Slog.logs==0&&!s.mRoydQuotaUsageWaitReported);
   if(control==4)need(s.installed.get("eth0")[0]==1000);
  }
  clean();s=new Source();s.sinkFailure=true;try{s.calculate(policy(),"eth0");throw new AssertionError();}catch(IllegalArgumentException wanted){}
  // The actual old calculation recreates the retained full-limit regrant.
  OldSource old=new OldSource();old.calculate(policy(),"eth0");need(old.installed.get("eth0")[1]==8473137&&old.mDeps.queries==0);
 }
}
'''
with tempfile.TemporaryDirectory() as temporary:
    out=Path(temporary);system=out/'android/system';system.mkdir(parents=True)
    (system/'ErrnoException.java').write_text('package android.system;public class ErrnoException extends Exception{public final int errno;public ErrnoException(int e){errno=e;}}\n')
    (system/'OsConstants.java').write_text('package android.system;public class OsConstants{public static final int ENOENT=2;}\n')
    (system/'Os.java').write_text('package android.system;public class Os{public static int error;public static Object stat(String p)throws ErrnoException{if(!p.equals("/sys/fs/selinux/enforce"))throw new AssertionError(p);if(error!=0)throw new ErrnoException(error);return new Object();}}\n')
    (out/'Harness.java').write_text(common+source('Source',b)+source('OldSource',a)+harness)
    result=subprocess.run([javac,'-d',str(out),*[str(p) for p in system.glob('*.java')],str(out/'Harness.java')],text=True,capture_output=True)
    assert result.returncode==0,(result.stdout,result.stderr)
    cases=[(None,2,False),('',2,False),('0',2,False),('01',2,False),('true',2,False),('1',2,True),('1',0,False),('1',13,False),('1',20,False),('1',1,False),('1',5,False)]
    for marker,error,enabled in cases:
        env=dict(os.environ);env.pop('ROYD_CONTAINER',None)
        if marker is not None:env['ROYD_CONTAINER']=marker
        result=subprocess.run([java,'-cp',str(out),'Harness',str(error),str(enabled).lower()],env=env,text=True,capture_output=True)
        assert result.returncode==0,(marker,error,result.stdout,result.stderr)
print('Actual pre/post calculation/dispatch, strict gate, readiness race, resumption, snooze/warning/stock and failure controls passed: '+str(len(cases))+' gate cases')
