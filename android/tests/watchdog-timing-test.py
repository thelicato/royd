"""Execute the pinned HandlerChecker and its read-only event timing report."""
from pathlib import Path
import os,shutil,subprocess,sys

root,temporary=map(Path,sys.argv[1:]);temporary.mkdir(parents=True)
relative=Path('frameworks/base/services/core/java/com/android/server/Watchdog.java')
source=temporary/relative;source.parent.mkdir(parents=True)
source.write_bytes((root/'android/tests/fixtures/android15/Watchdog.java').read_bytes())
for name in ('0073-framework-keep-watchdog-diagnostics-container-local.patch',
             '0091-framework-report-watchdog-checker-times.patch'):
    subprocess.run(['patch','--fuzz=0','-s','-p1','-d',str(temporary)],
        input=(root/'android/patches/android-15.0.0_r36'/name).read_text(),text=True,check=True)


def block(text,signature):
    start=text.index(signature);opening=text.index('{',start);depth=1
    for end in range(opening+1,len(text)):
        depth+=(text[end]=='{')-(text[end]=='}')
        if not depth:return text[start:end+1]
    raise AssertionError(signature)


patched=source.read_text();signature='private static void logRoydPreWatchdogCheckerTimes('
stock_run=block((root/'android/tests/fixtures/android15/Watchdog.java').read_text(),'private void run()')
reported_run=block(patched,'private void run()')
assert reported_run.replace('                        logRoydPreWatchdog(subject);\n','').replace(
    '                        logRoydPreWatchdogCheckerTimes(blockedCheckers);\n','')==stock_run
helper=block(patched,signature);old=block(patched,'private static void logRoydPreWatchdog(String subject)')
checker_signature='public static class HandlerChecker implements Runnable'
checker=block((root/'android/tests/fixtures/android15/WatchdogHandlerChecker.java').read_text(),checker_signature)
assert 'if (!sRoydLocalDiagnostics)' in helper
assert helper.count('checker.mClock.millis()')==1
assert not any(token in helper for token in ('mCompleted =','mStartTimeMillis =','postAtFrontOfQueue(',
    'pauseLocked(', 'resumeLocked(', 'doSysRq(', 'sleep(', 'setProperty(', 'FileWriter'))
ordering=['blockedCheckers = getCheckersWithStateLocked(WAITED_UNTIL_PRE_WATCHDOG);',
    'subject = describeCheckersLocked(blockedCheckers);','logRoydPreWatchdog(subject);',
    'logRoydPreWatchdogCheckerTimes(blockedCheckers);','pids = new ArrayList<>(mInterestingJavaPids);',
    'doWaitedPreDump = true;']
assert [patched.index(s) for s in ordering]==sorted(patched.index(s) for s in ordering)
if os.environ.get('ROYD_ANDROID15_WATCHDOG_SOURCE'):
    actual=(Path(os.environ['ROYD_ANDROID15_WATCHDOG_SOURCE'])/relative).read_text()
    assert block(actual,signature)==helper
    assert block(actual,'private void run()')==reported_run
    assert block(actual,checker_signature)==checker
    assert [actual.index(s) for s in ordering]==sorted(actual.index(s) for s in ordering)

java='''import java.time.*;
import java.util.*;
class WatchdogTimingContract {
    static final String TAG="Watchdog";
    static final int COMPLETED=0,WAITING=1,WAITED_UNTIL_PRE_WATCHDOG=2,OVERDUE=3;
    static final int PRE_WATCHDOG_TIMEOUT_RATIO=4;
    static boolean sRoydLocalDiagnostics;
    static class Slog {
        static final List<String> messages=new ArrayList<>();
        static void i(String tag,String text){messages.add(text);}
        static void wtf(String tag,String text){throw new AssertionError(text);}
    }
    static class Queue {boolean polling;boolean isPolling(){return polling;}}
    static class Looper {
        Queue queue=new Queue();Thread thread=new Thread("main");
        Queue getQueue(){return queue;}Thread getThread(){return thread;}
    }
    static class Handler {
        Looper looper=new Looper();List<Runnable> queued=new ArrayList<>();
        Looper getLooper(){return looper;}
        boolean postAtFrontOfQueue(Runnable value){queued.add(0,value);return true;}
    }
    interface Monitor {void monitor();}
    static class SystemClock {static Clock uptimeClock(){throw new AssertionError("Unexpected default clock");}}
    static class TestClock extends Clock {
        long now;int reads;
        public long millis(){reads++;return now;}
        public ZoneId getZone(){return ZoneOffset.UTC;}
        public Clock withZone(ZoneId z){return this;}
        public Instant instant(){return Instant.ofEpochMilli(now);}
    }
    static void need(boolean ok){if(!ok)throw new AssertionError(Slog.messages.toString());}
'''+checker+'\n'+old+'\n'+helper+'''
    static String state(HandlerChecker c,Handler h){
        return c.mCompleted+":"+c.mStartTimeMillis+":"+c.mWaitMaxMillis+":"+c.mPauseCount
            +":"+c.mPauseEndTimeMillis+":"+c.mCurrentMonitor+":"+h.queued.size();
    }
    static String expected(HandlerChecker c,long now){
        return "ROYD: pre-watchdog checker timing: name="+c.getName()
            +" start_uptime_ms="+c.mStartTimeMillis+" sampled_uptime_ms="+now
            +" elapsed_ms="+(now-c.mStartTimeMillis)+" wait_max_ms="+c.mWaitMaxMillis;
    }
    public static void main(String[] args){
        int cases=0;
        for(long start:new long[]{7,12345,9000000001L})for(long limit:new long[]{1000,60000,120000}){
            Object lock=new Object();TestClock clock=new TestClock();clock.now=start;
            Handler handler=new Handler();HandlerChecker c=new HandlerChecker(handler,"main thread",lock,clock);
            synchronized(lock){c.scheduleCheckLocked(limit);}
            need(!c.mCompleted&&c.mStartTimeMillis==start&&handler.queued.size()==1);
            clock.now=start+limit/4+237;need(c.getCompletionStateLocked()==WAITED_UNTIL_PRE_WATCHDOG);
            String before=state(c,handler);int reads=clock.reads;
            // The former event cannot recover the exact millisecond interval.
            Slog.messages.clear();sRoydLocalDiagnostics=true;logRoydPreWatchdog(c.describeBlockedStateLocked());
            need(Slog.messages.size()==1&&!Slog.messages.get(0).contains("start_uptime_ms="));
            Slog.messages.clear();reads=clock.reads;
            synchronized(lock){logRoydPreWatchdogCheckerTimes(List.of(c));}
            need(Slog.messages.equals(List.of(expected(c,clock.now))));
            need(clock.reads==reads+1&&state(c,handler).equals(before));
            need(c.getCompletionStateLocked()==WAITED_UNTIL_PRE_WATCHDOG);
            // Outside the gate there is no clock read, message or state mutation.
            Slog.messages.clear();sRoydLocalDiagnostics=false;reads=clock.reads;
            synchronized(lock){logRoydPreWatchdogCheckerTimes(List.of(c));}
            need(Slog.messages.isEmpty()&&clock.reads==reads&&state(c,handler).equals(before));
            // Existing completion and pause/resume behaviour remains executable.
            c.run();need(c.mCompleted&&c.getCompletionStateLocked()==COMPLETED);
            synchronized(lock){c.pauseLocked("control");c.scheduleCheckLocked(limit);}
            need(c.mCompleted&&c.mPauseCount==1);
            synchronized(lock){c.resumeLocked("control");clock.now+=111;c.scheduleCheckLocked(limit);}
            need(!c.mCompleted&&c.mStartTimeMillis==clock.now&&c.mPauseCount==0);
            cases++;
        }
        // Multiple blocked checkers retain distinct clocks and recorded starts.
        Object lock=new Object();TestClock a=new TestClock(),b=new TestClock();a.now=11;b.now=28;
        HandlerChecker x=new HandlerChecker(new Handler(),"main",lock,a);
        HandlerChecker y=new HandlerChecker(new Handler(),"i/o",lock,b);
        synchronized(lock){x.scheduleCheckLocked(60000);y.scheduleCheckLocked(120000);}
        a.now=15248;b.now=30299;Slog.messages.clear();sRoydLocalDiagnostics=true;
        synchronized(lock){logRoydPreWatchdogCheckerTimes(List.of(x,y));}
        need(Slog.messages.equals(List.of(expected(x,a.now),expected(y,b.now))));
        Slog.messages.clear();logRoydPreWatchdogCheckerTimes(List.of());need(Slog.messages.isEmpty());
        System.out.println("Actual HandlerChecker timing, stock gate and lifecycle controls passed: "+cases+" timing cases");
    }
}
'''
program=temporary/'WatchdogTimingContract.java';program.write_text(java)
home=os.environ.get('ROYD_TEST_JAVA_HOME')
javac=str(Path(home)/'bin/javac') if home else shutil.which('javac')
runner=str(Path(home)/'bin/java') if home else shutil.which('java')
if not (javac and runner):
    print('Java execution not run: set ROYD_TEST_JAVA_HOME for exact Watchdog timing contracts')
    sys.exit(0)
subprocess.run([javac,'-d',str(temporary),str(program)],check=True)
subprocess.run([runner,'-cp',str(temporary),'WatchdogTimingContract'],check=True,timeout=20)
print('Android 15 pre-watchdog checker timing contracts passed')
