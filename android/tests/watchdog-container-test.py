"""Exercise the patched diagnostic methods without any real SysRq file access."""
from pathlib import Path
import os
import re
import subprocess
import sys

root, temporary = map(Path, sys.argv[1:])
patch = root/'android/patches/android-15.0.0_r36/0073-framework-keep-watchdog-diagnostics-container-local.patch'
text = patch.read_text()
assert text.count('diff --git ') == 1 and not re.search(r'^-[^-]', text, re.M)
added = '\n'.join(line[1:] for line in text.splitlines() if line.startswith('+') and not line.startswith('+++'))
assert not re.search(r'mWatchdogTimeout|DEFAULT_TIMEOUT|PRE_WATCHDOG_TIMEOUT_RATIO|killProcess|System.exit|sleep\(|pauseWatching|setProperty', added)
relative = Path('frameworks/base/services/core/java/com/android/server/Watchdog.java')
source = temporary/relative
source.parent.mkdir(parents=True)
source.write_bytes((root/'android/tests/fixtures/android15/Watchdog.java').read_bytes())
subprocess.run(['patch', '--fuzz=0', '-s', '-p1', '-d', str(temporary)], input=text, text=True, check=True)
patched = source.read_text()


def method(text, signature):
    start = text.index(signature)
    opening = text.index('{', start)
    depth = 1
    for index in range(opening+1, len(text)):
        depth += (text[index] == '{') - (text[index] == '}')
        if depth == 0:
            return text[start:index+1]+'\n'
    raise AssertionError(signature)


signatures = ['private static boolean detectRoydLocalDiagnostics()',
              'private static void logRoydPreWatchdog(String subject)',
              'private void doSysRq(char c)', 'public void dump(']
methods = '\n'.join(method(patched, signature) for signature in signatures)
# No host FileWriter can be resolved by the harness: the only FileWriter is its mock.
assert 'java.io.FileWriter' not in methods
ordering = ['blockedCheckers = getCheckersWithStateLocked(WAITED_UNTIL_PRE_WATCHDOG);',
            'subject = describeCheckersLocked(blockedCheckers);', 'logRoydPreWatchdog(subject);',
            'pids = new ArrayList<>(mInterestingJavaPids);', 'doWaitedPreDump = true;']
assert [patched.index(s) for s in ordering] == sorted(patched.index(s) for s in ordering)
if os.environ.get('ROYD_ANDROID15_WATCHDOG_SOURCE'):
    actual = (Path(os.environ['ROYD_ANDROID15_WATCHDOG_SOURCE'])/relative).read_text()
    for signature in signatures: assert method(actual, signature) == method(patched, signature)
    assert 'private static final boolean sRoydLocalDiagnostics = detectRoydLocalDiagnostics();' in actual
    assert [actual.index(s) for s in ordering] == sorted(actual.index(s) for s in ordering)
java_home = os.environ.get('ROYD_TEST_JAVA_HOME')
if java_home:
    java = '''import java.io.IOException;
import java.io.PrintWriter;
import java.io.StringWriter;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
class WatchdogContract {
    @interface NonNull {}
    @interface Nullable {}
    static final String TAG="Watchdog";
    static boolean sRoydLocalDiagnostics;
    static final AtomicBoolean sRoydSysRqReported=new AtomicBoolean();
    static String marker, lastInfo;
    static int errno, probes, fault;
    static long mWatchdogTimeoutMillis=60000;
    static final AtomicInteger opens=new AtomicInteger(), writes=new AtomicInteger(),
            closes=new AtomicInteger(), infos=new AtomicInteger(), warnings=new AtomicInteger();
    static StringBuilder characters=new StringBuilder();
    static class System {
        static String getenv(String key) { check(key.equals("ROYD_CONTAINER"));return marker; }
    }
    static class android { static class system {
        static class OsConstants { static final int ENOENT=2; }
        static class ErrnoException extends Exception {
            final int errno; ErrnoException(int value) { errno=value; }
        }
        static class Os {
            static void stat(String path) throws ErrnoException {
                check(path.equals("/sys/fs/selinux/enforce"));probes++;
                if(errno!=0)throw new ErrnoException(errno);
            }
        }
    } }
    static class Slog {
        static void i(String tag,String value) { check(tag.equals(TAG));lastInfo=value;infos.incrementAndGet(); }
        static void w(String tag,String value,Exception error) {
            check(tag.equals(TAG) && value.equals("Failed to write to /proc/sysrq-trigger"));warnings.incrementAndGet();
        }
    }
    static class FileWriter {
        FileWriter(String path) throws IOException {
            check(path.equals("/proc/sysrq-trigger"));opens.incrementAndGet();
            if(fault==1)throw new IOException("open");
        }
        void write(char value) throws IOException {
            writes.incrementAndGet();characters.append(value);
            if(fault==2)throw new IOException("write");
        }
        void close() throws IOException { closes.incrementAndGet();if(fault==3)throw new IOException("close"); }
    }
    static void check(boolean value) { if(!value)throw new AssertionError(); }
'''+methods+'''
    static void reset() {
        sRoydSysRqReported.set(false);opens.set(0);writes.set(0);closes.set(0);
        infos.set(0);warnings.set(0);characters=new StringBuilder();lastInfo=null;
    }
    public static void main(String[] args) throws Exception {
        WatchdogContract instance=new WatchdogContract();int cases=0;
        for(String env:new String[]{null,"","0","true","1","01"," 1"})
        for(int error:new int[]{0,2,5,13,20})
        for(int failure=0;failure<4;failure++) {
            marker=env;errno=error;probes=0;fault=failure;reset();
            boolean gated="1".equals(env) && error==2;
            sRoydLocalDiagnostics=detectRoydLocalDiagnostics();check(sRoydLocalDiagnostics==gated);
            check(probes==("1".equals(env)?1:0));
            instance.doSysRq('w');instance.doSysRq('m');instance.doSysRq('l');
            if(gated) {check(opens.get()==0 && writes.get()==0 && closes.get()==0 && warnings.get()==0 && infos.get()==1);}
            else {
                check(infos.get()==0 && opens.get()==3 && writes.get()==(failure==1?0:3));
                check(closes.get()==(failure==1 || failure==2?0:3));
                check(warnings.get()==(failure==0?0:3));
                if(failure!=1)check(characters.toString().equals("wml"));
            }
            StringWriter output=new StringWriter();instance.dump(new PrintWriter(output),null);
            check(output.toString().equals("WatchdogTimeoutMillis=60000\\n"+(gated?"RoydHostSysRq=disabled\\n":"")));
            int before=infos.get();String subject="Blocked in monitor example.Lock on foreground thread";
            logRoydPreWatchdog(subject);check(infos.get()==before+(gated?1:0));
            if(gated)check(lastInfo.equals("ROYD: pre-watchdog blocked checkers: "+subject));
            check(mWatchdogTimeoutMillis==60000);cases++;
        }
        reset();sRoydLocalDiagnostics=true;fault=0;
        Thread[] workers=new Thread[20];
        for(int n=0;n<workers.length;n++) {workers[n]=new Thread(()->{for(int i=0;i<100;i++)instance.doSysRq('l');});workers[n].start();}
        for(Thread thread:workers){thread.join(10000);check(!thread.isAlive());}
        check(infos.get()==1 && opens.get()==0 && writes.get()==0);
        java.lang.System.out.println("Watchdog gate/stock errors/dump/subject passed: "+cases+" combinations; bounded concurrent marker passed");
    }
}
'''
    target = temporary/'WatchdogContract.java'
    target.write_text(java)
    subprocess.run([str(Path(java_home)/'bin/javac'), '-d', str(temporary), str(target)], check=True)
    subprocess.run([str(Path(java_home)/'bin/java'), '-cp', str(temporary), 'WatchdogContract'], check=True, timeout=30)
else:
    print('Java execution not run: set ROYD_TEST_JAVA_HOME')
print('Android 15 container Watchdog diagnostic contract passed; no real SysRq requests issued')
