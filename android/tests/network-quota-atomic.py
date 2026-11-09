"""Execute actual old/new quota methods and the policy message across strict gates."""
from pathlib import Path
import hashlib,json,os,shutil,subprocess,sys,tempfile
root=Path(sys.argv[1]).resolve();fixtures=root/'android/tests/fixtures/android15';sys.path.insert(0,str(fixtures))
from SettingsSearchPatchFixture import sources,method
patch=root/'android/patches/android-15.0.0_r36/0089-services-replace-oci-ethernet-quotas-atomically.patch'
prefix='frameworks/base/services/core/java/com/android/server/net/'
before=sources(patch,prefixes=(prefix,));after=sources(patch,after=True,prefixes=(prefix,))
a,b=(before[prefix+'NetworkManagementService.java'],after[prefix+'NetworkManagementService.java'])
x,y=(before[prefix+'NetworkPolicyManagerService.java'],after[prefix+'NetworkPolicyManagerService.java'])
stock=(fixtures/'NetworkQuotaStockMethods.java').read_text();metadata=json.loads((fixtures/'NetworkQuotaStockMethods.json').read_text())
assert hashlib.sha256(stock.encode()).hexdigest()==metadata['fixture_sha256']
for row in metadata['sources']:assert hashlib.sha256(method(stock,row['method']).strip().encode()).hexdigest()==row['sha256']

def block(text,needle):
 start=text.index(needle);opening=text.index('{',start);depth=1
 for end in range(opening+1,len(text)):
  depth+=(text[end]=='{')-(text[end]=='}')
  if not depth:return text[start:end+1]
 raise AssertionError(needle)
oldset=method(a,'setInterfaceQuota');newset=method(b,'setInterfaceQuota')
gate=method(b,'shouldUseRoydOciQuotaReplacement')
oldcase=block(x,'case MSG_UPDATE_INTERFACE_QUOTAS:');newcase=block(y,'case MSG_UPDATE_INTERFACE_QUOTAS:')
dump=block(b,'if (mUseRoydOciQuotaReplacement)')
registration=root/'android/patches/android-15.0.0_r36/0086-services-observe-oci-ethernet-policy-usage.patch'
added='\n'.join(v[1:] for v in registration.read_text().splitlines() if v.startswith('+') and not v.startswith('+++'))
policygate=method(added,'shouldObserveRoydEthernetStats')
assert gate.replace('shouldUseRoydOciQuotaReplacement','shouldObserveRoydEthernetStats').strip()==policygate.strip()
actual=os.environ.get('ROYD_ANDROID15_ATOMIC_QUOTA_SOURCE')
if actual:
 path=Path(actual)/prefix;nms=(path/'NetworkManagementService.java').read_text();npm=(path/'NetworkPolicyManagerService.java').read_text()
 for name in ('setInterfaceQuota','shouldUseRoydOciQuotaReplacement'):assert method(nms,name).strip()==method(b,name).strip(),name
 assert block(npm,'case MSG_UPDATE_INTERFACE_QUOTAS:')==newcase and dump in nms
 for name,source in [('removeInterfaceQuota',nms),('setInterfaceLimit',npm),('removeInterfaceLimit',npm)]:assert method(source,name).strip()==method(stock,name).strip(),name
jdk=os.environ.get('ROYD_TEST_JAVA_HOME');candidate=root/'.work/android-src-15/prebuilts/jdk/jdk21/linux-x86'
if not jdk and (candidate/'bin/javac').is_file():jdk=str(candidate)
javac=str(Path(jdk)/'bin/javac') if jdk else shutil.which('javac');java=str(Path(jdk)/'bin/java') if jdk else shutil.which('java')
if not javac or not java:print('Java execution skipped: set ROYD_TEST_JAVA_HOME for atomic quota contracts');raise SystemExit(0)
common=r'''
import java.util.*;
import java.io.*;
class RemoteException extends Exception {}
class ServiceSpecificException extends RuntimeException {}
class PermissionUtils {
 static boolean denied;static int checks;
 static void enforceNetworkStackPermission(Object context){checks++;if(denied)throw new SecurityException("permission");}
}
class Slog {static int logs;static void i(String tag,String text){if(!tag.equals("NetworkManagement")||!text.equals("ROYD: replacing OCI eth0 byte quotas atomically"))throw new AssertionError(text);logs++;}}
class Log {static int wtfs;static void wtf(String tag,String text,Throwable error){wtfs++;}}
class Netd {
 Object lock;Long left=0L;int sets,removes,uncharged,charged;int failure;boolean release;
 void bandwidthSetInterfaceQuota(String iface,long bytes)throws RemoteException {
  if(!Thread.holdsLock(lock))throw new AssertionError("lost quota lock");sets++;
  if(release)packet();
  if(failure==1)throw new RemoteException();if(failure==2)throw new ServiceSpecificException();if(failure==3)throw new IllegalArgumentException("unexpected native failure");
  left=bytes;
 }
 void bandwidthRemoveInterfaceQuota(String iface)throws RemoteException{if(!Thread.holdsLock(lock))throw new AssertionError("lost lock");removes++;left=null;if(release)packet();}
 boolean packet(){if(left==null){uncharged++;return true;}if(left>=1228){left-=1228;charged++;return true;}left=0L;return false;}
}
interface Manager {void setInterfaceQuota(String iface,long bytes)throws RemoteException;void removeInterfaceQuota(String iface)throws RemoteException;}
class Stats {int calls;boolean fail;String iface;long warning,limit;
 void setStatsProviderWarningAndLimitAsync(String i,long w,long l){calls++;iface=i;warning=w;limit=l;if(fail)throw new IllegalArgumentException("provider failure");}}
class IfaceQuotas {String iface;long warning=7,limit=1;IfaceQuotas(String i){iface=i;}}
class Message {int what=1;Object obj;Message(Object o){obj=o;}}
'''

def management(name,body):
 return 'class '+name+' implements Manager {\n'+r'''
 static final String TAG="NetworkManagement";final Object mContext=new Object(),mQuotaLock=new Object();
 final HashMap<String,Long> mActiveQuotas=new HashMap<>(),mActiveAlerts=new HashMap<>();
 final Netd mNetdService=new Netd();
 final boolean mUseRoydOciQuotaReplacement=shouldUseRoydOciQuotaReplacement();
 boolean mRoydQuotaReplacementReported;
'''+name+'(){mNetdService.lock=mQuotaLock;}\n'+gate+'\n'+body+'\n'+method(stock,'removeInterfaceQuota')+'\n'+r'''
 String status(){StringWriter s=new StringWriter();PrintWriter pw=new PrintWriter(s);synchronized(mQuotaLock){
'''+dump+r'''}pw.flush();return s.toString();}
}
'''

def policy(name,case):
 return 'class '+name+' {\n'+r'''
 static final int MSG_UPDATE_INTERFACE_QUOTAS=1;static final String TAG="NetworkPolicy";
 final boolean mObserveRoydEthernetStats=shouldObserveRoydEthernetStats();
 Manager mNetworkManager;Stats mNetworkStats=new Stats();
'''+policygate+'\n'+method(stock,'setInterfaceLimit')+'\n'+method(stock,'removeInterfaceLimit')+'\n'+r'''
 boolean update(String iface){Message msg=new Message(new IfaceQuotas(iface));switch(msg.what){
'''+case+r'''default:return false;}}
}
'''
harness=r'''
public class Harness {
 static void need(boolean value){if(!value)throw new AssertionError();}
 static void reset(){PermissionUtils.denied=false;PermissionUtils.checks=0;Slog.logs=0;Log.wtfs=0;}
 static void seed(Management m,String iface){m.mActiveQuotas.put(iface,2556L);m.mActiveAlerts.put(iface,777L);m.mNetdService.left=0L;}
 public static void main(String[]args)throws Exception{
  android.system.Os.error=Integer.parseInt(args[0]);boolean expected=Boolean.parseBoolean(args[1]);
  reset();Management m=new Management();need(m.mUseRoydOciQuotaReplacement==expected);
  Policy p=new Policy();need(p.mObserveRoydEthernetStats==expected);
  for(String iface:new String[]{"eth0","eth1"}){
   reset();m=new Management();seed(m,iface);m.mNetdService.release=true;p=new Policy();p.mNetworkManager=m;
   need(p.update(iface));need(p.mNetworkStats.calls==1&&p.mNetworkStats.iface.equals(iface)&&p.mNetworkStats.warning==7&&p.mNetworkStats.limit==1);
   boolean active=expected&&iface.equals("eth0");
   need(m.mNetdService.removes==(active?0:1)&&m.mNetdService.uncharged==(active?0:2));
   need(m.mActiveQuotas.get(iface)==1L&&m.mActiveAlerts.containsKey(iface)==active);
   need(Slog.logs==(active?1:0)&&!m.mNetdService.packet()&&Log.wtfs==0);
  }
  // The exact old message plus old method recreates the open interval.
  reset();OldManagement old=new OldManagement();old.mActiveQuotas.put("eth0",2556L);old.mNetdService.release=true;
  OldPolicy oldp=new OldPolicy();oldp.mNetworkManager=old;need(oldp.update("eth0")&&old.mNetdService.removes==1&&old.mNetdService.uncharged==2);
  reset();m=new Management();m.setInterfaceQuota("eth0",100);need(m.mNetdService.sets==1&&Slog.logs==0);
  need(m.status().equals(expected?"royd interface quota replacement: mode=atomic used=no\n":""));
  reset();m=new Management();seed(m,"eth0");PermissionUtils.denied=true;
  try{m.setInterfaceQuota("eth0",1);throw new AssertionError();}catch(SecurityException wanted){}
  need(PermissionUtils.checks==1&&m.mNetdService.sets==0&&m.mActiveQuotas.get("eth0")==2556L&&Slog.logs==0);PermissionUtils.denied=false;
  for(long value:new long[]{0,-1,Long.MIN_VALUE}){
   reset();m=new Management();seed(m,"eth0");try{m.setInterfaceQuota("eth0",value);throw new AssertionError();}catch(IllegalStateException wanted){}
   need(m.mNetdService.sets==0&&m.mActiveQuotas.get("eth0")==2556L&&m.mActiveAlerts.get("eth0")==777L&&Slog.logs==0);
  }
  if(expected){
   for(int failure:new int[]{1,2,3}){
    reset();m=new Management();seed(m,"eth0");m.mNetdService.failure=failure;
    try{m.setInterfaceQuota("eth0",1);throw new AssertionError();}catch(IllegalStateException wanted){need(failure!=3);}catch(IllegalArgumentException wanted){need(failure==3);}
    need(m.mNetdService.left==0L&&m.mActiveQuotas.get("eth0")==2556L&&m.mActiveAlerts.get("eth0")==777L&&Slog.logs==0&&!m.mRoydQuotaReplacementReported);
   }
   reset();m=new Management();seed(m,"eth0");m.mNetdService.failure=2;p=new Policy();p.mNetworkManager=m;need(p.update("eth0"));
   need(Log.wtfs==1&&m.mNetdService.removes==0&&m.mNetdService.left==0L&&m.mActiveQuotas.get("eth0")==2556L);
   reset();m=new Management();seed(m,"eth0");m.setInterfaceQuota("eth0",Long.MAX_VALUE);m.setInterfaceQuota("eth0",1);
   need(Slog.logs==1&&m.mNetdService.left==1L&&m.mActiveAlerts.get("eth0")==777L&&m.status().equals("royd interface quota replacement: mode=atomic used=yes\n"));
  }else{
   reset();m=new Management();seed(m,"eth0");try{m.setInterfaceQuota("eth0",1);throw new AssertionError();}catch(IllegalStateException wanted){}
   need(m.mNetdService.sets==0&&m.mActiveQuotas.get("eth0")==2556L&&Slog.logs==0);
  }
  reset();m=new Management();seed(m,"eth0");p=new Policy();p.mNetworkManager=m;p.mNetworkStats.fail=true;
  try{p.update("eth0");throw new AssertionError();}catch(IllegalArgumentException wanted){need(wanted.getMessage().equals("provider failure"));}
 }
}
'''
with tempfile.TemporaryDirectory() as temporary:
 out=Path(temporary);system=out/'android/system';system.mkdir(parents=True)
 (system/'ErrnoException.java').write_text('package android.system; public class ErrnoException extends Exception { public final int errno; public ErrnoException(int e){errno=e;} }\n')
 (system/'OsConstants.java').write_text('package android.system; public class OsConstants { public static final int ENOENT=2; }\n')
 (system/'Os.java').write_text('package android.system; public class Os { public static int error; public static Object stat(String p)throws ErrnoException { if(!p.equals("/sys/fs/selinux/enforce"))throw new AssertionError(p);if(error!=0)throw new ErrnoException(error);return new Object(); } }\n')
 (out/'Harness.java').write_text(common+management('Management',newset)+management('OldManagement',oldset)+policy('Policy',newcase)+policy('OldPolicy',oldcase)+harness)
 compiled=subprocess.run([javac,'-d',str(out),*[str(p) for p in system.glob('*.java')],str(out/'Harness.java')],capture_output=True,text=True)
 assert compiled.returncode==0,(compiled.stdout,compiled.stderr)
 cases=[(None,2,False),('',2,False),('0',2,False),('01',2,False),('true',2,False),('1',2,True),('1',0,False),('1',13,False),('1',20,False),('1',1,False),('1',5,False)]
 for marker,error,expected in cases:
  env=dict(os.environ);env.pop('ROYD_CONTAINER',None)
  if marker is not None:env['ROYD_CONTAINER']=marker
  result=subprocess.run([java,'-cp',str(out),'Harness',str(error),str(expected).lower()],env=env,text=True,capture_output=True)
  assert result.returncode==0,(marker,error,result.stdout,result.stderr)
print('Actual old/new quota messages, strict gates, permissions, atomic failure state, alerts, marker and stock controls passed: '+str(len(cases))+' gate cases')
