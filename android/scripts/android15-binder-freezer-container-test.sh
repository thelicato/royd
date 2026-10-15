#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
patch_file="$root/android/patches/android-15.0.0_r36/0053-framework-isolate-binder-freezer-operations.patch"
[ "$(grep -c '^diff --git ' "$patch_file")" -eq 2 ]
[ "$(grep -c '^-[^-]' "$patch_file")" -eq 2 ]
! grep -Eq '^\+.*(setProcessFrozen|freezePackageCgroup|removeProcessLocked|unfreezePackageCgroup|async)' "$patch_file"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
source_dir="$tmp/frameworks/base/services/core/java/com/android/server/am"
mkdir -p "$source_dir"
cp "$root/android/tests/fixtures/android15/Freezer.java" "$source_dir/"
cp "$root/android/tests/fixtures/android15/ProcessList.java" "$source_dir/"
patch -s --fuzz=0 -p1 -d "$tmp" <"$patch_file"
grep -Fq 'return isBinderFreezerAllowed() && nativeIsFreezerSupported();' "$source_dir/Freezer.java"
grep -Fq 'if (pid > 0 && mService.getFreezer().isBinderFreezerAllowed())' "$source_dir/ProcessList.java"
if [ -n "${ROYD_TEST_JAVA_HOME:-}" ]; then
  cat >"$tmp/FreezerContract.java" <<'JAVA'
import java.util.ArrayList;
import java.util.List;
class FreezerContract {
    static final String TAG = "ActivityManager", TAG_AM = TAG;
    static String marker;
    static boolean selinux, support, failNative;
    static int infos, errors, supportCalls, freezeCalls, infoCalls, cgroupCalls, processCalls;
    static int result, binderPid, binderTimeout;
    static boolean binderFrozen;
    static final List<String> events = new ArrayList<>();
    static void check(boolean value) { if (!value) throw new AssertionError(events); }
    static class System {
        static String getenv(String name) { check(name.equals("ROYD_CONTAINER")); return marker; }
    }
    static class SELinux { static boolean isSELinuxEnabled() { return selinux; } }
    static class Slog {
        static void i(String tag, String message) {
            check(tag.equals(TAG) && message.equals(
                    "ROYD: Binder freezing disabled: PID namespace safety is unqualified"));
            infos++;
        }
        static void e(String tag, String message) {
            check(tag.equals(TAG) && message.startsWith("Unable to freeze binder for 101:"));
            errors++;
        }
    }
    static class Process {
        static void setProcessFrozen(int pid, int uid, boolean value) {
            check(pid == 101 && uid == 10001); processCalls++;
        }
    }
    static int nativeFreeze(int pid, boolean frozen, int timeout) {
        freezeCalls++; binderPid = pid; binderFrozen = frozen; binderTimeout = timeout;
        events.add("binder:" + pid);
        if (failNative) throw new RuntimeException("fault");
        return result;
    }
    static int nativeInfo(int pid) {
        infoCalls++; check(pid == 101);
        if (failNative) throw new RuntimeException("fault");
        return result;
    }
    static boolean nativeSupport() { supportCalls++; return support; }
    static final int EAGAIN = 11;
    static class Pair<A, B> {
        final A first; final B second;
        Pair(A a, B b) { first = a; second = b; }
    }
    static class ProcessRecord {
        final int pid;
        ProcessRecord(int value) { pid = value; }
        int getPid() { return pid; }
    }
    static class Service {
        final Freezer freezer = new Freezer();
        Freezer getFreezer() { return freezer; }
    }
    static Service mService;
    static boolean freezePackageCgroup(int uid, boolean value) {
        check(uid == 10001 && value); cgroupCalls++; events.add("cgroup:" + uid); return true;
    }
JAVA
  sed '/^package /d; /^import /d; s/^class Freezer/static class Freezer/;
    s/private static native int nativeFreezeBinder(int pid, boolean freeze, int timeoutMs);/private static int nativeFreezeBinder(int pid, boolean freeze, int timeoutMs) { return nativeFreeze(pid, freeze, timeoutMs); }/;
    s/private static native int nativeGetBinderFreezeInfo(int pid);/private static int nativeGetBinderFreezeInfo(int pid) { return nativeInfo(pid); }/;
    s/private static native boolean nativeIsFreezerSupported();/private static boolean nativeIsFreezerSupported() { return nativeSupport(); }/' \
    "$source_dir/Freezer.java" >>"$tmp/FreezerContract.java"
  sed 's/^class ProcessList/static class ProcessList/' "$source_dir/ProcessList.java" \
    >>"$tmp/FreezerContract.java"
  cat >>"$tmp/FreezerContract.java" <<'JAVA'
    public static void main(String[] args) {
        marker = args[0].equals("unset") ? null : args[0];
        selinux = Boolean.parseBoolean(args[1]);
        boolean allowed = !("1".equals(marker) && !selinux);
        mService = new Service();
        Freezer freezer = mService.getFreezer();
        check(freezer.isBinderFreezerAllowed() == allowed);
        for (int i = 0; i < 2; i++) {
            support = i == 1;
            check(freezer.isFreezerSupported() == (allowed && support));
        }
        check(supportCalls == (allowed ? 2 : 0));
        for (boolean frozen : new boolean[] {false, true}) {
            for (int rc : new int[] {0, -EAGAIN, -22, -38, 7}) {
                result = rc;
                if (allowed) {
                    check(freezer.freezeBinder(101, frozen, 25) == rc);
                    check(binderPid == 101 && binderFrozen == frozen && binderTimeout == 25);
                    check(freezer.getBinderFreezeInfo(101) == rc);
                } else {
                    try { freezer.freezeBinder(101, frozen, 25); throw new AssertionError(); }
                    catch (UnsupportedOperationException expected) {}
                    try { freezer.getBinderFreezeInfo(101); throw new AssertionError(); }
                    catch (UnsupportedOperationException expected) {}
                }
            }
            freezer.setProcessFrozen(101, 10001, frozen);
        }
        check(processCalls == 2 && freezeCalls == (allowed ? 10 : 0)
                && infoCalls == (allowed ? 10 : 0));
        if (allowed) {
            failNative = true;
            try { freezer.freezeBinder(101, true, 25); throw new AssertionError(); }
            catch (RuntimeException expected) { check(expected.getMessage().equals("fault")); }
            try { freezer.getBinderFreezeInfo(101); throw new AssertionError(); }
            catch (RuntimeException expected) { check(expected.getMessage().equals("fault")); }
            failNative = false;
        }
        ProcessList list = new ProcessList();
        List<Pair<ProcessRecord, Boolean>> procs = List.of(
                new Pair<>(new ProcessRecord(-1), false),
                new Pair<>(new ProcessRecord(0), false),
                new Pair<>(new ProcessRecord(101), false));
        for (int mode = 0; mode < 4; mode++) {
            result = mode == 1 ? -EAGAIN : mode == 2 ? -22 : 0;
            failNative = mode == 3;
            freezeCalls = errors = 0; events.clear();
            list.freezeBinderAndPackageCgroup(procs, 10001);
            check(freezeCalls == (allowed ? mode == 1 ? 2 : 1 : 0));
            check(errors == (allowed && mode != 0 ? 1 : 0));
            check(events.get(events.size() - 1).equals("cgroup:10001"));
            if (!allowed) check(events.size() == 1);
            if (allowed) check(binderPid == 101 && binderFrozen && binderTimeout == 10);
        }
        check(cgroupCalls == 4 && infos == (allowed ? 0 : 1));
        new Freezer();
        check(infos == (allowed ? 0 : 1));
    }
}
JAVA
  "$ROYD_TEST_JAVA_HOME/bin/javac" -d "$tmp" "$tmp/FreezerContract.java"
  for marker in unset '' 0 true 01 1; do
    for selinux in false true; do
      "$ROYD_TEST_JAVA_HOME/bin/java" -cp "$tmp" FreezerContract "$marker" "$selinux"
    done
  done
else
  printf '%s\n' 'Java execution skipped: set ROYD_TEST_JAVA_HOME to test Binder freezer control flow'
fi
printf '%s\n' 'Android 15 Binder-freezer container contract passed'
