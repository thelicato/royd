from pathlib import Path
import re
import subprocess
import sys

tree, out, jdk = map(Path, sys.argv[1:])
source = (tree / 'packages/modules/Connectivity/service/src/com/android/server/BpfNetMaps.java').read_text()
def method(name, return_type):
    found = re.search(r'    (?:private static|public) ' + return_type + ' ' + name + r'\(.*?\n    }', source, re.S)
    assert found, name
    return found.group(0)
gate = method('isRoydContainerWithoutSelinux', 'boolean')
swap = method('swapActiveStatsMap', 'void')
assert 'sRoydKernelRcuUnavailable' not in source
text = '''
public class RcuSwap {
  static final int ENOENT=2, STATS_SELECT_MAP_A=0, STATS_SELECT_MAP_B=1, CURRENT_STATS_MAP_CONFIGURATION_KEY=1;
  static String marker;
  static int statError, calls, updates, reads, mapError;
  static int[] results;
  static class System { static String getenv(String name) { check(name.equals("ROYD_CONTAINER")); return marker; } }
  static class ErrnoException extends Exception { int errno; ErrnoException(int n) { errno=n; } }
  static class Os { static void stat(String path) throws ErrnoException { check(path.equals("/sys/fs/selinux/enforce")); if(statError!=0) throw new ErrnoException(statError); } }
  static class U32 { long val; U32(long n) { val=n; } }
  static class ServiceSpecificException extends RuntimeException { ServiceSpecificException(int n,String text) { super(text); } }
  static final Object sCurrentStatsMapConfigLock=new Object();
  static class Map {
    long value;
    U32 getValue(int key) throws ErrnoException { check(key==1); reads++; if(mapError!=0) throw new ErrnoException(mapError); return new U32(value); }
    void updateEntry(int key,U32 next) throws ErrnoException { check(key==1); updates++; value=next.val; }
  }
  static Map sConfigurationMap;
  static class Dependencies { int synchronizeKernelRCU() { return results[calls++]; } }
  Dependencies mDeps=new Dependencies();
  static void throwIfPreT(String text) { }
  static void maybeThrow(int error,String text) { if(error!=0) throw new ServiceSpecificException(-error,text); }
  static void check(boolean ok) { if(!ok) throw new AssertionError(); }
  GATE
  SWAP
  public static void main(String[] args) {
    int cases=0;
    for(String value:new String[]{null,"","0","true","1"})
    for(int probe:new int[]{0,2,13,5,20})
    for(int pre:new int[]{0,-1,-97,-5})
    for(int post:new int[]{0,-1,-5})
    for(int initial:new int[]{0,1}) {
      marker=value; statError=probe; mapError=0; calls=updates=reads=0;
      boolean gated="1".equals(value)&&probe==ENOENT;
      sConfigurationMap=new Map(); sConfigurationMap.value=initial;
      results=gated?new int[]{pre,post}:new int[]{post};
      boolean failed=false;
      try { new RcuSwap().swapActiveStatsMap(); } catch(ServiceSpecificException expected) { failed=true; }
      check(failed==((gated&&pre!=0)||post!=0));
      boolean changed=!gated||pre==0;
      check(updates==(changed?1:0)&&reads==(changed?1:0));
      check(sConfigurationMap.value==(changed?1-initial:initial));
      check(calls==(gated?(pre==0?2:1):1));
      cases++;
    }
    marker="1"; statError=2; mapError=5; calls=updates=reads=0;
    sConfigurationMap=new Map(); results=new int[]{0,0};
    try { new RcuSwap().swapActiveStatsMap(); throw new AssertionError(); } catch(ServiceSpecificException expected) { }
    check(calls==1&&updates==0&&reads==1);
    java.lang.System.out.println("Actual Java RCU preflight/swap/post-barrier contracts passed: "+cases+" selections and map failure");
  }
}
'''.replace('GATE', gate).replace('SWAP', re.sub(r'^    @.*\n', '', swap, flags=re.M))
(out / 'RcuSwap.java').write_text(text)
subprocess.run([str(jdk / 'bin/javac'), '-d', str(out), str(out / 'RcuSwap.java')], check=True)
subprocess.run([str(jdk / 'bin/java'), '-cp', str(out), 'RcuSwap'], check=True)
