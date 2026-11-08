"""Exercise the patched policy callback through the pinned real framework adapter."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

root = Path(sys.argv[1]).resolve()
fixtures = root/'android/tests/fixtures/android15'
spec = importlib.util.spec_from_file_location('patch_fixture', fixtures/'SettingsSearchPatchFixture.py')
patch_fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(patch_fixture)
patch = root/'android/patches/android-15.0.0_r36/0087-services-dispatch-oci-ethernet-usage-callback.patch'
path = 'frameworks/base/services/core/java/com/android/server/net/NetworkPolicyManagerService.java'


def block(text, needle):
    start = text.rfind('\n', 0, text.index(needle))+1
    opening = text.index('{', start)
    depth = 1
    for end in range(opening+1, len(text)):
        depth += (text[end] == '{')-(text[end] == '}')
        if depth == 0:
            return text[start:end+1]
    raise AssertionError(needle)


old = block(patch_fixture.sources(patch, prefixes=('frameworks/base/',))[path],
            'private class StatsCallback extends')
fixed = block(patch_fixture.sources(patch, after=True, prefixes=('frameworks/base/',))[path],
              'private class StatsCallback extends')
predecessor = root/'android/patches/android-15.0.0_r36/0086-services-observe-oci-ethernet-policy-usage.patch'
with tempfile.TemporaryDirectory() as temporary:
    helper = fixtures/'NetworkPolicyUsagePatchFixture.py'
    subprocess.run([sys.executable, str(helper), str(predecessor), str(patch)],
                   cwd=temporary, check=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    for item in (predecessor, patch):
        subprocess.run(['patch', '--batch', '--fuzz=0', '-p1', '-i', str(item)],
                       cwd=temporary, check=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    applied = (Path(temporary)/path).read_text()
    assert block(applied, 'private class StatsCallback extends') == fixed
    assert 'registerNetworkStatsCallbacks(executor);' in applied
    subprocess.run([sys.executable, str(helper), str(predecessor), str(patch)],
                   cwd=temporary, check=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    assert (Path(temporary)/path).read_text() == applied
assert block(old, 'void onThresholdReached(int').split('{', 1)[1] == block(
    fixed, 'void handleThresholdReached(').split('{', 1)[1]
assert block(old, 'boolean isAnyCallbackReceived(') == block(fixed, 'boolean isAnyCallbackReceived(')
fixture = (fixtures/'NetworkStatsUsageCallback.java').read_text()
metadata = json.loads((fixtures/'NetworkStatsUsageCallback.json').read_text())
assert hashlib.sha256(fixture.encode()).hexdigest() == metadata['fixture_sha256']
tree = Path(os.environ.get('ROYD_ANDROID15_OCI_STATS_SOURCE', root/'.work/android-src-15'))
framework = tree/'packages/modules/Connectivity'/metadata['path']
if framework.is_file():
    source = framework.read_text()
    for needle in ('public static abstract class UsageCallback',
                   'private static class UsageCallbackWrapper'):
        assert block(source, needle) == block(fixture, needle)
if os.environ.get('ROYD_ANDROID15_OCI_STATS_SOURCE'):
    source = (tree/path).read_text()
    assert block(source, 'private class StatsCallback extends') == fixed
    assert 'if (!mStatsCallback.isAnyCallbackReceived()) return 0;' in source

jdk = os.environ.get('ROYD_TEST_JAVA_HOME')
if not jdk:
    candidate = root/'.work/android-src-15/prebuilts/jdk/jdk21/linux-x86'
    if (candidate/'bin/javac').is_file():
        jdk = str(candidate)
javac = str(Path(jdk)/'bin/javac') if jdk else shutil.which('javac')
java = str(Path(jdk)/'bin/java') if jdk else shutil.which('java')
if not javac or not java:
    print('Java execution skipped: set ROYD_TEST_JAVA_HOME for OCI callback-dispatch contracts')
    raise SystemExit(0)

harness = '''import java.util.*;
import java.util.concurrent.*;
@interface NonNull {}
@interface Nullable {}
@interface SystemApi { int client(); }
class ConnectivityManager { static final int TYPE_MOBILE=0, TYPE_WIFI=1, TYPE_NONE=-1; }
class NetworkTemplate {
 static final int MATCH_MOBILE=1, MATCH_WIFI=4, MATCH_ETHERNET=5;
 final int rule; NetworkTemplate(int r){rule=r;}
 int getMatchRule(){return rule;} Set<String> getSubscriberIds(){return Set.of();}
}
class DataUsageRequest {
 final NetworkTemplate template;
 DataUsageRequest(int rule){template=new NetworkTemplate(rule);}
}
class IUsageCallback {
 abstract static class Stub {
  public abstract void onThresholdReached(DataUsageRequest request);
  public abstract void onCallbackReleased(DataUsageRequest request);
 }
}
class Log {
 static int errors;
 static void e(String tag,String message){errors++;}
 static void d(String tag,String message){}
}
class NetworkStatsManager {
 static final int MODULE_LIBRARIES=1;
 static final String TAG="test";
 static final boolean DBG=false;
''' + fixture + '''
 // Owned entry points invoke the unchanged actual wrapper above.
 static void deliver(UsageCallback cb,int rule,Executor executor) {
  new UsageCallbackWrapper(executor,cb).onThresholdReached(new DataUsageRequest(rule));
 }
 static void released(UsageCallback cb) {
  UsageCallbackWrapper wrapper=new UsageCallbackWrapper(Runnable::run,cb);
  DataUsageRequest request=new DataUsageRequest(5);
  wrapper.onCallbackReleased(request);wrapper.onThresholdReached(request);
 }
}
'''
for name, callback in [('OldSource', old), ('FixedSource', fixed)]:
    harness += '''class ''' + name + ''' {
 final boolean mObserveRoydEthernetStats;
 final Object mNetworkPoliciesSecondLock=new Object();
 final List<String> updates=new ArrayList<>();
 private final StatsCallback mStatsCallback=new StatsCallback();
 boolean failRules;
 ''' + name + '''(boolean gate){mObserveRoydEthernetStats=gate;}
 void record(String action) {
  if(!Thread.holdsLock(mNetworkPoliciesSecondLock))throw new AssertionError("lost policy lock");
  updates.add(action);
 }
 void updateNetworkRulesNL(){record("rules");if(failRules)throw new IllegalStateException("rules failure");}
 void updateNetworkEnabledNL(){record("enabled");}
 void updateNotificationsNL(){record("notifications");}
 boolean ready(){return mStatsCallback.isAnyCallbackReceived();}
 NetworkStatsManager.UsageCallback callback(){return mStatsCallback;}
''' + callback + '\n}\n'
harness += '''public final class Harness {
 static void need(boolean condition,String message){if(!condition)throw new AssertionError(message);}
 public static void main(String[] args) {
  for(boolean gate:new boolean[]{false,true})for(int rule:new int[]{1,4,5,3,9}) {
   OldSource old=new OldSource(gate);FixedSource fixed=new FixedSource(gate);
   need(!old.ready()&&!fixed.ready(),"readiness without a callback");
   NetworkStatsManager.deliver(old.callback(),rule,Runnable::run);
   NetworkStatsManager.deliver(fixed.callback(),rule,Runnable::run);
   boolean stock=rule==1||rule==4,expected=stock||(gate&&rule==5);
   need(old.ready()==stock&&fixed.ready()==expected,"wrong callback dispatch");
   need(fixed.updates.equals(expected?List.of("rules","enabled","notifications"):List.of()),"changed policy handler");
  }
  FixedSource queued=new FixedSource(true);List<Runnable> queue=new ArrayList<>();
  NetworkStatsManager.deliver(queued.callback(),5,queue::add);
  need(!queued.ready()&&queue.size()==1,"callback bypassed executor");queue.remove(0).run();
  need(queued.ready()&&queued.updates.size()==3,"queued callback lost");
  FixedSource released=new FixedSource(true);NetworkStatsManager.released(released.callback());
  need(!released.ready()&&Log.errors==1,"released callback delivered or error hidden");
  FixedSource rejected=new FixedSource(true);
  try {
   NetworkStatsManager.deliver(rejected.callback(),5,r->{throw new RejectedExecutionException();});
   throw new AssertionError("executor failure hidden");
  }catch(RejectedExecutionException expected){need(!rejected.ready(),"rejected callback set readiness");}
  for(boolean gate:new boolean[]{false,true}) {
   FixedSource failed=new FixedSource(gate);failed.failRules=true;
   try {
    failed.callback().onThresholdReached(0,null);
    throw new AssertionError("policy failure hidden");
   }catch(IllegalStateException expected) {
    need(failed.ready()&&failed.updates.equals(List.of("rules")),"changed stock failure order");
   }
  }
 }
}
'''
with tempfile.TemporaryDirectory() as temporary:
    out = Path(temporary)
    source = out/'Harness.java'
    source.write_text(harness)
    subprocess.run([javac, '-d', str(out), str(source)], check=True)
    subprocess.run([java, '-cp', str(out), 'Harness'], check=True)
print('OCI policy callback-dispatch contracts passed (15 cases, actual adapter and original loss regression)')
