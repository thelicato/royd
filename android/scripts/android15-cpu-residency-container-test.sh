#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
patch="$root/android/patches/android-15.0.0_r36/0051-framework-report-unavailable-cpu-residency.patch"
[ "$(grep -c '^diff --git ' "$patch")" -eq 1 ]
grep -Fq 'diff --git a/frameworks/base/core/java/com/android/internal/os/KernelCpuSpeedReader.java' "$patch"
[ "$(grep -c '^-[^-]' "$patch")" -eq 2 ]
[ "$(grep -c '^-            Slog.e(TAG, "Failed to read cpu-freq: "' "$patch")" -eq 2 ]
! grep -Eq '^\+.*(Arrays.fill|return null|readDelta|readAbsolute|FileReader|setThreadPolicy|mLastSpeedTimesMs)' "$patch"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
source_dir="$tmp/frameworks/base/core/java/com/android/internal/os"
mkdir -p "$source_dir"
cp "$root/android/tests/fixtures/android15/KernelCpuSpeedReader.java" "$source_dir/"
patch -s --fuzz=0 -p1 -d "$tmp" <"$patch"
if [ -n "${ROYD_TEST_JAVA_HOME:-}" ]; then
  cat >"$tmp/CpuResidency.java" <<'JAVA'
import java.io.IOException;
import java.io.FileNotFoundException;
import java.util.Arrays;
import java.util.Iterator;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
class CpuResidency {
    static String marker;
    static boolean selinux;
    static IOException openError, readError, closeError;
    static String[] lines;
    static int opens, closes, allows, restores, activePolicy;
    static final AtomicInteger infos = new AtomicInteger(), errors = new AtomicInteger();
    static void check(boolean value) { if (!value) throw new AssertionError(); }
    static void zero(long[] values) { check(Arrays.equals(values, new long[] {0, 0})); }
    static void times(long[] values, long first, long second) {
        check(Arrays.equals(values, new long[] {first, second}));
    }
    static class System {
        static String getenv(String name) { check(name.equals("ROYD_CONTAINER")); return marker; }
    }
    static class SELinux { static boolean isSELinuxEnabled() { return selinux; } }
    static class OsConstants { static final int ENOENT = 2, EACCES = 13, EIO = 5, ENOTDIR = 20,
            _SC_CLK_TCK = 1; }
    static class Os {
        static long sysconf(int name) { check(name == OsConstants._SC_CLK_TCK); return 100; }
    }
    static class ErrnoException extends Exception {
        final int errno;
        ErrnoException(int value) { errno = value; }
    }
    static class StrictMode {
        static class ThreadPolicy {}
        static final ThreadPolicy original = new ThreadPolicy();
        static ThreadPolicy allowThreadDiskReads() {
            check(activePolicy == 0); activePolicy++; allows++; return original;
        }
        static void setThreadPolicy(ThreadPolicy value) {
            check(value == original && activePolicy == 1); activePolicy--; restores++;
        }
    }
    static class Slog {
        static void i(String tag, String message) {
            check(tag.equals("KernelCpuSpeedReader"));
            check(message.matches("ROYD: CPU frequency residency unavailable for "
                    + "/sys/devices/system/cpu/cpu[0-9]+/cpufreq/stats/time_in_state"));
            infos.incrementAndGet();
        }
        static void e(String tag, String message) {
            check(tag.equals("KernelCpuSpeedReader") && message.equals("Failed to read cpu-freq: fault"));
            errors.incrementAndGet();
        }
    }
    static class TextUtils {
        static class SimpleStringSplitter {
            Iterator<String> parts;
            SimpleStringSplitter(char separator) { check(separator == ' '); }
            void setString(String line) { parts = Arrays.asList(line.split(" ")).iterator(); }
            String next() { return parts.next(); }
        }
    }
    static class FileReader {
        FileReader(String path) throws IOException {
            check(path.matches("/sys/devices/system/cpu/cpu[0-9]+/cpufreq/stats/time_in_state"));
            opens++;
            if (openError != null) throw openError;
        }
    }
    static class BufferedReader implements AutoCloseable {
        int index;
        BufferedReader(FileReader reader) {}
        String readLine() throws IOException {
            if (readError != null) throw readError;
            return index < lines.length ? lines[index++] : null;
        }
        public void close() throws IOException { closes++; if (closeError != null) throw closeError; }
    }
JAVA
  sed '/^package /d; /^import /d; s/^public class KernelCpuSpeedReader/static class KernelCpuSpeedReader/' \
    "$source_dir/KernelCpuSpeedReader.java" >>"$tmp/CpuResidency.java"
  cat >>"$tmp/CpuResidency.java" <<'JAVA'
    static IOException fault(int kind) {
        IOException result = kind < 5 || kind == 7
                ? new FileNotFoundException("fault") : new IOException("fault");
        if (kind < 4 || kind == 5) {
            int errno = kind == 1 ? OsConstants.EACCES : kind == 2 ? OsConstants.EIO
                    : kind == 3 ? OsConstants.ENOTDIR : OsConstants.ENOENT;
            result.initCause(new ErrnoException(errno));
        } else if (kind == 7) result.initCause(new IllegalStateException());
        return result;
    }
    public static void main(String[] args) throws Exception {
        for (String value : new String[] {null, "", "0", "true", "1"}) {
            marker = value;
            for (boolean enabled : new boolean[] {false, true}) {
                selinux = enabled;
                boolean gated = "1".equals(value) && !enabled;
                for (int kind = 0; kind < 8; kind++) {
                    infos.set(0); errors.set(0);
                    opens = closes = allows = restores = activePolicy = 0;
                    readError = closeError = null;
                    KernelCpuSpeedReader reader = new KernelCpuSpeedReader(0, 2);
                    // Construction is not a read and cannot promise an availability report.
                    check(infos.get() == 0 && errors.get() == 0 && opens == 0);
                    openError = fault(kind);
                    zero(reader.readDelta()); zero(reader.readAbsolute());
                    boolean unavailable = gated && kind == 0;
                    check(infos.get() == (unavailable ? 1 : 0));
                    check(errors.get() == (unavailable ? 0 : 2));
                    check(opens == 2 && closes == 0);
                    int expectedErrors = errors.get();
                    openError = null;
                    lines = new String[] {"100 12", "200 20"};
                    times(reader.readDelta(), 120, 200);
                    times(reader.readDelta(), 0, 0);
                    lines = new String[] {"100 5", "200 7"};
                    times(reader.readDelta(), 50, 70); // Stock hotplug reset handling.
                    times(reader.readAbsolute(), 50, 70);
                    openError = fault(0);
                    zero(reader.readAbsolute()); zero(reader.readDelta());
                    expectedErrors += gated ? 0 : 2;
                    check(infos.get() == (gated ? 1 : 0));
                    check(errors.get() == expectedErrors);
                    openError = null;
                    lines = new String[] {"100 8", "200 11"};
                    times(reader.readDelta(), 30, 40); // Missing reads must not reset history.
                    times(reader.readAbsolute(), 80, 110);
                    openError = fault(1); // Permission failures remain visible after ENOENT.
                    zero(reader.readDelta()); zero(reader.readAbsolute());
                    expectedErrors += 2;
                    openError = null;
                    readError = fault(6);
                    zero(reader.readDelta()); zero(reader.readAbsolute());
                    expectedErrors += 2;
                    readError = null;
                    closeError = fault(6);
                    zero(reader.readDelta()); zero(reader.readAbsolute());
                    expectedErrors += 2;
                    closeError = null;
                    lines = new String[] {"100 invalid"};
                    try { reader.readDelta(); throw new AssertionError(); }
                    catch (NumberFormatException expected) {}
                    try { reader.readAbsolute(); throw new AssertionError(); }
                    catch (NumberFormatException expected) {}
                    check(errors.get() == expectedErrors && infos.get() == (gated ? 1 : 0));
                    check(opens == 18 && closes == 12 && allows == 18 && restores == 18
                            && activePolicy == 0);
                }
            }
        }
        marker = "1"; selinux = false; infos.set(0); errors.set(0);
        KernelCpuSpeedReader reader = new KernelCpuSpeedReader(1, 2);
        Thread[] reporters = new Thread[16];
        for (int i = 0; i < reporters.length; i++) {
            reporters[i] = new Thread(() -> reader.reportReadError(fault(0)));
            reporters[i].start();
        }
        for (Thread reporter : reporters) reporter.join();
        check(infos.get() == 1 && errors.get() == 0);
    }
}
JAVA
  "$ROYD_TEST_JAVA_HOME/bin/javac" -d "$tmp" "$tmp/CpuResidency.java"
  "$ROYD_TEST_JAVA_HOME/bin/java" -cp "$tmp" CpuResidency
fi
printf '%s\n' 'Android 15 CPU residency container contract passed'
