"""Compile the actual patch's callback registration and strict container probe."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

root = Path(sys.argv[1]).resolve()
patch = root/'android/patches/android-15.0.0_r36/0086-services-observe-oci-ethernet-policy-usage.patch'
lines = patch.read_text().splitlines()
added = '\n'.join(x[1:] for x in lines if x.startswith('+') and not x.startswith('+++'))
removed = '\n'.join(x[1:] for x in lines if x.startswith('-') and not x.startswith('---'))


def method(text, name):
    start = text.index(name)
    start = text.rfind('\n', 0, start)+1
    opening = text.index('{', start)
    depth = 1
    for i in range(opening+1, len(text)):
        depth += (text[i] == '{')-(text[i] == '}')
        if depth == 0:
            return text[start:i+1]
    raise AssertionError(name)


gate = method(added, 'boolean shouldObserveRoydEthernetStats(')
register = method(added, 'void registerNetworkStatsCallbacks(')
field = next(x for x in added.splitlines() if 'private final boolean mObserveRoydEthernetStats =' in x)
assert removed.count('mNetworkStats.registerUsageCallback(') == 2
assert '+            registerNetworkStatsCallbacks(executor);' in lines
actual = os.environ.get('ROYD_ANDROID15_OCI_STATS_SOURCE')
if actual:
    source = (Path(actual)/'frameworks/base/services/core/java/com/android/server/net/NetworkPolicyManagerService.java').read_text()
    assert method(source, 'boolean shouldObserveRoydEthernetStats(') == gate
    assert method(source, 'void registerNetworkStatsCallbacks(') == register
    assert field in source and 'if (!mStatsCallback.isAnyCallbackReceived()) return 0;' in source

jdk = os.environ.get('ROYD_TEST_JAVA_HOME')
if not jdk:
    candidate = root/'.work/android-src-15/prebuilts/jdk/jdk21/linux-x86'
    if (candidate/'bin/javac').is_file():
        jdk = str(candidate)
javac = str(Path(jdk)/'bin/javac') if jdk else shutil.which('javac')
java = str(Path(jdk)/'bin/java') if jdk else shutil.which('java')
if not javac or not java:
    print('Java execution skipped: set ROYD_TEST_JAVA_HOME for OCI network-policy contracts')
    raise SystemExit(0)

with tempfile.TemporaryDirectory() as temporary:
    out = Path(temporary)
    system = out/'android/system';system.mkdir(parents=True)
    (system/'ErrnoException.java').write_text('package android.system; public final class ErrnoException extends Exception { public final int errno; public ErrnoException(int value) { errno=value; } }\n')
    (system/'OsConstants.java').write_text('package android.system; public final class OsConstants { public static final int ENOENT=2; }\n')
    (system/'Os.java').write_text('''package android.system;
public final class Os {
 public static int error, calls;
 public static Object stat(String path) throws ErrnoException {
  calls++;
  if (!path.equals("/sys/fs/selinux/enforce")) throw new AssertionError(path);
  if (error == -1) throw new SecurityException("unavailable test permission");
  if (error != 0) throw new ErrnoException(error);
  return new Object();
 }
}
''')
    harness = '''import java.util.*;
import java.util.concurrent.Executor;
class NetworkTemplate {
 static final int MATCH_ETHERNET=5;
 final int rule;
 NetworkTemplate(int rule) { this.rule=rule; }
 static class Builder { final int rule; Builder(int r) { rule=r; } NetworkTemplate build() { return new NetworkTemplate(rule); } }
}
class Slog {
 static int logs;
 static void i(String tag, String text) {
  if (!tag.equals("NetworkPolicy") || !text.equals("ROYD: observing OCI Ethernet usage for network policy")) throw new AssertionError(text);
  logs++;
 }
}
class Source {
 static final int MATCH_MOBILE=1, MATCH_WIFI=4;
 static final String TAG="NetworkPolicy";
 final Object mStatsCallback=new Object();
 final List<Integer> rules=new ArrayList<>();
 final List<Executor> executors=new ArrayList<>();
 boolean fail;
 final Registry mNetworkStats=new Registry();
 class Registry {
  void registerUsageCallback(NetworkTemplate template, long threshold, Executor executor, Object callback) {
   if (threshold != 0 || callback != mStatsCallback) throw new AssertionError("changed stock registration");
   if (fail && template.rule==5) throw new IllegalStateException("real registration failure");
   rules.add(template.rule);executors.add(executor);
  }
 }
''' + field+'\n'+gate+'\n'+register+'''
 void run(Executor executor) { registerNetworkStatsCallbacks(executor); }
 void oldRun(Executor executor) {
''' + removed + '''
 }
}
public final class Harness {
 public static void main(String[] args) {
  android.system.Os.error=Integer.parseInt(args[0]);
  Executor executor=Runnable::run;
  Source source=null;String status="pass";
  try {
   source=new Source();source.fail=args[1].equals("fail");
   if(args[1].equals("old")) source.oldRun(executor); else source.run(executor);
  } catch (SecurityException error) { status="security"; }
    catch (IllegalStateException error) { status="registration"; }
  if(source != null && source.executors.stream().anyMatch(x -> x != executor)) throw new AssertionError("changed executor");
  System.out.println("{\\"status\\":\\""+status+"\\",\\"rules\\":"+(source == null ? "[]" : source.rules.toString())+",\\"stat_calls\\":"+android.system.Os.calls+",\\"logs\\":"+Slog.logs+"}");
 }
}
'''
    (out/'Harness.java').write_text(harness)
    subprocess.run([javac, '-d', str(out), *[str(x) for x in system.glob('*.java')], str(out/'Harness.java')], check=True)
    cases = [(None,2,False),('',2,False),('0',2,False),('01',2,False),('true',2,False),
             ('1',0,False),('1',2,True),('1',5,False),('1',13,False),('1',20,False),('1',40,False)]
    for container, error, enabled in cases:
        env = dict(os.environ);env.pop('ROYD_CONTAINER',None)
        if container is not None:env['ROYD_CONTAINER']=container
        value = json.loads(subprocess.check_output([java,'-cp',str(out),'Harness',str(error),'good'],env=env,text=True))
        assert value == dict(status='pass',rules=[1,4,5] if enabled else [1,4],stat_calls=1 if container=='1' else 0,logs=1 if enabled else 0), (container,error,value)
    for mode, error, status in [('fail',2,'registration'),('good',-1,'security')]:
        value=json.loads(subprocess.check_output([java,'-cp',str(out),'Harness',str(error),mode],env=dict(os.environ,ROYD_CONTAINER='1'),text=True))
        assert value['status']==status and value['logs']==0
        if mode=='fail':assert value['rules']==[1,4]
    old=json.loads(subprocess.check_output([java,'-cp',str(out),'Harness','2','old'],env=dict(os.environ,ROYD_CONTAINER='1'),text=True))
    assert old['rules']==[1,4] and old['logs']==0, old
print('OCI network-policy actual-method contracts passed (13 gated/failure cases and original missing-Ethernet regression)')
