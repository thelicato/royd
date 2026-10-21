#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
patch=$root/android/patches/android-15.0.0_r36/0064-framework-keep-container-uid-cpu-cleanup-local.patch
[ "$(grep -c '^diff --git ' "$patch")" -eq 1 ]
! grep -Eq '^-[^-]|^\+.*(removeUid\(|removeUidsInRange\(|readDelta|readAbsolute|FileWriter|StrictMode|mBpf)' "$patch"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
file=frameworks/base/core/java/com/android/internal/os/KernelCpuUidTimeReader.java
mkdir -p "$tmp/$(dirname "$file")"
cp "$root/android/tests/fixtures/android15/KernelCpuUidTimeReader.java" "$tmp/$file"
patch --batch --fuzz=0 -p1 -d "$tmp" <"$patch" >/dev/null
source=${ROYD_ANDROID15_UID_CPU_SOURCE:-$tmp/$file}
if [ -z "${ROYD_TEST_JAVA_HOME:-}" ]; then
  printf '%s\n' 'Java execution skipped: set ROYD_TEST_JAVA_HOME for UID CPU cleanup contracts'
  exit 0
fi
cat >"$tmp/UidCpuCleanup.java" <<'JAVA'
import java.io.IOException;
import java.nio.CharBuffer;
import java.util.*;
import java.util.concurrent.atomic.AtomicInteger;
class UidCpuCleanup {
    static String marker;
    static int errno, failure, opens, writes, flushes, closes, allows, restores, policy, bpfRemovals;
    static boolean interfacePresent;
    static final AtomicInteger infos = new AtomicInteger(), errors = new AtomicInteger(), probes = new AtomicInteger();
    static final List<String> payloads = new ArrayList<>();
    static void check(boolean ok) { if (!ok) throw new AssertionError(); }
    static class System { static String getenv(String name) { check(name.equals("ROYD_CONTAINER")); return marker; } }
    static class android { static class system {
        static class OsConstants { static final int ENOENT=2; }
        static class ErrnoException extends Exception { final int errno; ErrnoException(int value) { errno=value; } }
        static class Os { static void stat(String path) throws ErrnoException {
            check(path.equals("/sys/fs/selinux/enforce")); probes.incrementAndGet();
            if (errno!=0) throw new ErrnoException(errno);
        } }
    } }
    @interface Nullable {}
    @interface VisibleForTesting {}
    static class Clock { static final Clock SYSTEM_CLOCK=new Clock(); long elapsedRealtime() { return 10000; } }
    static class StrictMode {
        static int allowThreadDiskWritesMask() { check(policy==0); policy=1; allows++; return 27; }
        static void setThreadPolicyMask(int value) { check(value==27 && policy==1); policy=0; restores++; }
    }
    static class Slog {
        static void i(String tag,String text) {
            check(tag.equals("KernelCpuUidUserSysTimeReader"));
            check(text.equals("ROYD: keeping UID CPU-stat cleanup local to the container")); infos.incrementAndGet();
        }
        static void d(String tag,String text) {}
        static void e(String tag,String text) { check(text.equals("start UID 10004 > end UID 10002")); errors.incrementAndGet(); }
        static void e(String tag,String text,IOException error) {
            check(text.startsWith("failed to remove uids ") && text.endsWith(" from uid_cputime module")); errors.incrementAndGet();
        }
        static void wtf(String tag,String text) { throw new AssertionError(text); }
    }
    static class SparseArray<T> {
        final TreeMap<Integer,T> values=new TreeMap<>();
        void delete(int uid) { values.remove(uid); }
        void put(int uid,T value) { values.put(uid,value); }
        T get(int uid) { return values.get(uid); }
        int indexOfKey(int uid) { return new ArrayList<>(values.keySet()).indexOf(uid); }
        void removeAtRange(int start,int count) {
            List<Integer> keys=new ArrayList<>(values.keySet());
            for(int i=start;i<start+count;i++) values.remove(keys.get(i));
        }
    }
    static class FileWriter implements AutoCloseable {
        FileWriter(String path) throws IOException {
            check(path.equals("/proc/uid_cputime/remove_uid_range") && policy==1); opens++;
            if (!interfacePresent || failure==1) throw new IOException("open failed");
        }
        void write(String text) throws IOException { writes++; if(failure==2) throw new IOException("write failed"); payloads.add(text); }
        void flush() throws IOException { flushes++; if(failure==3) throw new IOException("flush failed"); }
        public void close() throws IOException { closes++; if(failure==4) throw new IOException("close failed"); }
    }
    static class IntArray {}
    static class KernelCpuUidBpfMapReader { void removeUidsInRange(int first,int last) { bpfRemovals++; } }
    static class ProcFileIterator implements AutoCloseable {
        final Iterator<String> lines;
        ProcFileIterator(String[] input) { lines=Arrays.asList(input).iterator(); }
        CharBuffer nextLine() { return lines.hasNext()?CharBuffer.wrap(lines.next()):null; }
        public void close() {}
    }
    static class KernelCpuProcStringReader {
        String[] lines={"10001: 10 20", "10002: 30 40", "10003: 50 60", "10004: 70 80"};
        int reads;
        static KernelCpuProcStringReader getUserSysTimeReaderInstance() { return new KernelCpuProcStringReader(); }
        ProcFileIterator open(boolean ignoreCache) { reads++; return new ProcFileIterator(lines); }
    }
    static int asLongs(CharBuffer line,long[] values) {
        String[] parts=line.toString().split("[: ]+");
        for(int i=0;i<parts.length;i++) values[i]=Long.parseLong(parts[i]);
        return parts.length;
    }
JAVA
# Keep the real base and user/system reader, stopping before unrelated frequency readers.
sed '/^package /d; /^import /d; s/^public abstract class KernelCpuUidTimeReader/static abstract class KernelCpuUidTimeReader/' "$source" |
  awk '/^    public static class KernelCpuUidUserSysTimeReader/ { reader=1 }
    { print } reader && /^    }/ { print "}"; exit }' >>"$tmp/UidCpuCleanup.java"
cat >>"$tmp/UidCpuCleanup.java" <<'JAVA'
    static class BpfReader extends KernelCpuUidTimeReader<long[]> {
        BpfReader() { super(new KernelCpuProcStringReader(),new KernelCpuUidBpfMapReader(),false,Clock.SYSTEM_CLOCK); }
        void readDeltaImpl(Callback<long[]> cb,boolean force) {}
        void readAbsoluteImpl(Callback<long[]> cb) {}
    }
    static void reset() {
        opens=writes=flushes=closes=allows=restores=policy=bpfRemovals=0;
        infos.set(0); errors.set(0); probes.set(0); payloads.clear();
        KernelCpuUidTimeReader.KernelCpuUidUserSysTimeReader.sRoydKernelCleanupReported.set(false);
    }
    public static void main(String[] args) throws Exception {
        int cases=0;
        for(String env:new String[]{null,"","0","true","1"})
        for(int probeError:new int[]{0,2,5,13,20})
        for(boolean present:new boolean[]{false,true})
        for(int fault=0;fault<=4;fault++) {
            reset(); marker=env; errno=probeError; interfacePresent=present; failure=fault;
            boolean gate="1".equals(env) && errno==2;
            var reader=new KernelCpuUidTimeReader.KernelCpuUidUserSysTimeReader(false);
            Map<Integer,long[]> times=new TreeMap<>();
            reader.readDelta((uid,value)->times.put(uid,value.clone()));
            check(times.size()==4 && reader.mLastTimes.values.size()==4);
            reader.removeUid(10002); reader.removeUidsInRange(10003,10004);
            check(reader.mLastTimes.values.keySet().equals(Set.of(10001)));
            reader.removeUidsInRange(10004,10002); // Preserve stock invalid-range handling.
            check(reader.mLastTimes.values.keySet().equals(Set.of(10001)));
            check(opens==(gate?0:3) && allows==opens && restores==opens && policy==0);
            check(infos.get()==(gate?1:0) && probes.get()==("1".equals(env)?3:0));
            check(errors.get()==1+(!gate && (!present || fault!=0)?3:0));
            check(writes==(!gate && present && fault!=1?3:0));
            check(flushes==(!gate && present && fault!=1 && fault!=2?3:0));
            check(closes==(!gate && present && fault!=1?3:0));
            if(!gate && present && fault!=1 && fault!=2) {
                check(payloads.equals(List.of("10002-10002","10003-10004","10004-10002")));
            } else check(payloads.isEmpty());
            reader.mReader.lines=new String[]{"10001: 11 22","10002: 31 42","10003: 51 62","10004: 71 82"};
            times.clear(); reader.readDelta((uid,value)->times.put(uid,value.clone()));
            check(Arrays.equals(times.get(10001),new long[]{1,2}));
            check(Arrays.equals(times.get(10002),new long[]{31,42}));
            check(Arrays.equals(times.get(10003),new long[]{51,62}));
            times.clear(); reader.readAbsolute((uid,value)->times.put(uid,value.clone()));
            check(times.size()==4 && Arrays.equals(times.get(10001),new long[]{11,22}));
            check(reader.mReader.reads==3 && bpfRemovals==0);
            BpfReader bpf=new BpfReader(); bpf.removeUid(10002); bpf.removeUidsInRange(10003,10004);
            check(bpfRemovals==2); cases++;
        }
        reset(); marker="1"; errno=2; interfacePresent=true; failure=0;
        Thread[] reporters=new Thread[16];
        for(int i=0;i<reporters.length;i++) {
            reporters[i]=new Thread(()->new KernelCpuUidTimeReader.KernelCpuUidUserSysTimeReader(false).removeUid(99000));
            reporters[i].start();
        }
        for(Thread thread:reporters) thread.join();
        check(infos.get()==1 && opens==0 && allows==0 && probes.get()==16);
        java.lang.System.out.println("UID CPU cleanup production contracts passed: "+cases+" cases and concurrent marker");
    }
}
JAVA
"$ROYD_TEST_JAVA_HOME/bin/javac" -d "$tmp" "$tmp/UidCpuCleanup.java"
"$ROYD_TEST_JAVA_HOME/bin/java" -cp "$tmp" UidCpuCleanup
