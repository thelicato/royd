#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
patch="$root/android/patches/android-15.0.0_r36/0056-framework-keep-container-host-clock-read-only.patch"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
[ "$(grep -c '^diff --git ' "$patch")" -eq 2 ]
! grep -q '^-[^-]' "$patch"
[ "$(grep -c 'ROYD: host wall clock is read-only' "$patch")" -eq 1 ]
! grep -Eq '^\+.*(setTime\(|sTimeConfidence = confidence|enforcePermission|putInt|setProperty|settimeofday|clock_settime)' "$patch"
if [ -n "${ROYD_TEST_JAVA_HOME:-}" ]; then
  cat >"$tmp/SystemClockTime.java" <<'JAVA'
class SystemClockTime {
    @interface CurrentTimeMillisLong {}
    @interface NonNull {}
    @interface TimeConfidence {}
    static boolean sRoydHostClockReadOnly;
    static long sNativeData = 123, lastMillis;
    static int sTimeConfidence, nativeCalls, probes;
    static String marker, lastLog;
    static int errno;
    static class System {
        static String getenv(String name) { check(name.equals("ROYD_CONTAINER")); return marker; }
    }
    static class android { static class system {
        static class OsConstants { static final int ENOENT = 2; }
        static class ErrnoException extends Exception {
            int errno;
            ErrnoException(int code) { errno=code; }
        }
        static class Os {
            static void stat(String path) throws ErrnoException {
                check(path.equals("/sys/fs/selinux/enforce")); probes++;
                if (errno != 0) throw new ErrnoException(errno);
            }
        }
    } }
    static class DebugLog { void log(String text) { lastLog=text; } }
    static DebugLog sTimeDebugLog = new DebugLog();
    static void setTime(long data, long millis) {
        check(data == 123); nativeCalls++; lastMillis=millis;
    }
    static void addDebugLogEntry(String message) { sTimeDebugLog.log(message); }
    static void check(boolean condition) { if (!condition) throw new AssertionError(); }
JAVA
  for method in 'private static boolean detectRoydHostClock' 'public static boolean isRoydHostClockReadOnly' 'public static void setTimeAndConfidence'; do
    awk -v method="$method" '
      index(substr($0, 2), method) { copy=1 }
      copy && /^[ +]/ { print substr($0, 2) }
      copy && /^[ +]    }/ { exit }
    ' "$patch" >>"$tmp/SystemClockTime.java"
  done
  cat >>"$tmp/SystemClockTime.java" <<'JAVA'
    static class Alarm {
        final Object mLock = new Object();
        int injections;
        class Injector {
            void setCurrentTimeMillis(long value, int confidence, String log) {
                injections++; setTimeAndConfidence(value, confidence, log);
            }
        }
        Injector mInjector = new Injector();
JAVA
  awk '/^     boolean setTimeImpl/ { copy=1 }
    copy && /^[ +]/ { print substr($0, 2) }
    copy && /^     }/ { exit }' "$patch" >>"$tmp/SystemClockTime.java"
  cat >>"$tmp/SystemClockTime.java" <<'JAVA'
    }
    public static void main(String[] args) {
        int cases=0;
        for (String value : new String[] {null, "", "0", "true", "1"})
        for (int code : new int[] {0, 2, 5, 13})
        for (long millis : new long[] {-1, 1, 1700000000000L}) {
            marker=value; errno=code; probes=0;
            boolean gated="1".equals(value) && code == 2;
            sRoydHostClockReadOnly=detectRoydHostClock();
            check(sRoydHostClockReadOnly == gated);
            check(probes == ("1".equals(value) ? 1 : 0));
            nativeCalls=0; sTimeConfidence=7; lastLog=null;
            setTimeAndConfidence(millis, 100, "boot/direct update");
            check(nativeCalls == (gated ? 0 : 1));
            check(sTimeConfidence == (gated ? 7 : 100));
            check(gated ? lastLog.startsWith("ROYD: refused") : lastMillis == millis);
            nativeCalls=0; sTimeConfidence=7;
            Alarm alarm=new Alarm();
            check(alarm.setTimeImpl(millis, 100, "manual/automatic update") == !gated);
            check(alarm.injections == (gated ? 0 : 1));
            check(nativeCalls == (gated ? 0 : 1));
            check(sTimeConfidence == (gated ? 7 : 100));
            if (!gated) check(lastMillis == millis);
            cases++;
        }
        java.lang.System.out.println("Host-clock gate/direct/AlarmManager contracts passed: " + cases);
    }
}
JAVA
  "$ROYD_TEST_JAVA_HOME/bin/javac" -d "$tmp" "$tmp/SystemClockTime.java"
  "$ROYD_TEST_JAVA_HOME/bin/java" -cp "$tmp" SystemClockTime
else
  printf '%s\n' 'Java execution skipped: set ROYD_TEST_JAVA_HOME for host-clock contracts'
fi
printf '%s\n' 'Android 15 read-only host-clock container contract passed'
