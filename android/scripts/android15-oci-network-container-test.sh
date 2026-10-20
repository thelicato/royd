#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
source_dir="$root/android/royd/vendor/royd/network"
patch="$root/android/patches/android-15.0.0_r36/0055-connectivity-publish-oci-network.patch"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
[ "$(grep -c '^diff --git ' "$patch")" -eq 2 ]
! grep -q '^-[^-]' "$patch"
grep -Fq 'startMonitoringDone.block();' "$patch"
grep -Fq 'if (SdkLevel.isAtLeastV()) {' "$patch"
grep -Fq 'RoydOciNetwork.startIfContainer(mContext);' "$patch"
grep -Fq 'if (!"1".equals(System.getenv("ROYD_CONTAINER"))) return;' "$source_dir/RoydOciNetwork.java"
grep -Fq 'Os.stat("/sys/fs/selinux/enforce");' "$source_dir/RoydOciNetwork.java"
grep -Fq 'if (error.errno != OsConstants.ENOENT) {' "$source_dir/RoydOciNetwork.java"
grep -Fq 'if (sInstance == null)' "$source_dir/RoydOciNetwork.java"
grep -Fq 'if (mOffer != this) return;' "$source_dir/RoydOciNetwork.java"
grep -Fq 'mProvider.unregisterNetworkOffer(old);' "$source_dir/RoydOciNetwork.java"
! grep -Eq 'IpClient|Runtime.getRuntime|ProcessBuilder|setMtu\(|interfaceSet|setDefaultNetwork|setAcceptUnvalidated|setExplicitlySelected|VALIDATED|NOT_METERED|skip464xlat|setNat64' "$source_dir/RoydOciNetwork.java"
if [ -n "${ROYD_TEST_JAVA_HOME:-}" ]; then
  "$ROYD_TEST_JAVA_HOME/bin/javac" -d "$tmp" "$source_dir/RoydOciNetworkConfig.java" \
    "$root/android/tests/fixtures/android15/RoydOciNetworkConfigTest.java"
  "$ROYD_TEST_JAVA_HOME/bin/java" -cp "$tmp" com.android.server.connectivity.RoydOciNetworkConfigTest
  cat >"$tmp/RoydOciNetwork.java" <<'JAVA'
import java.util.function.IntConsumer;
import java.io.IOException;
class RoydOciNetwork {
    static RoydOciNetwork sInstance;
    static String marker;
    static int errno, probes, starts, warnings;
    static class Context {}
    IntConsumer mMeteredInterface;
    RoydOciNetwork(Context context, IntConsumer policy) { starts++; mMeteredInterface=policy; }
    static void check(boolean condition) { if (!condition) throw new AssertionError(); }
    static class System {
        static String getenv(String name) { check(name.equals("ROYD_CONTAINER")); return marker; }
    }
    static class OsConstants { static final int ENOENT = 2; }
    static class ErrnoException extends Exception {
        int errno;
        ErrnoException(int code) { errno = code; }
    }
    static class Os {
        static void stat(String path) throws ErrnoException {
            check(path.equals("/sys/fs/selinux/enforce")); probes++;
            if (errno != 0) throw new ErrnoException(errno);
        }
    }
    static final String TAG = "RoydOciNetwork";
    static class Log { static void w(String tag, String text, Exception error) { warnings++; } }
JAVA
  awk '/^    public static synchronized void startIfContainer/ { copy=1 }
    copy { print }
    copy && /^    }/ { exit }' "$source_dir/RoydOciNetwork.java" >>"$tmp/RoydOciNetwork.java"
  awk '/^    private void updateMeteredInterface/ { copy=1 }
    copy { print }
    copy && /^    }/ { exit }' "$source_dir/RoydOciNetwork.java" >>"$tmp/RoydOciNetwork.java"
  cat >>"$tmp/RoydOciNetwork.java" <<'JAVA'
    public static void main(String[] args) throws Exception {
        for (String value : new String[] {null, "", "0", "true", "1"}) {
            for (int code : new int[] {0, 2, 5, 13}) {
                marker=value; errno=code; probes=starts=warnings=0; sInstance=null;
                startIfContainer(new Context(), index -> {});
                startIfContainer(new Context(), index -> {});
                check(probes == ("1".equals(value) ? 2 : 0));
                check(starts == ("1".equals(value) && code == 2 ? 1 : 0));
                check(warnings == ("1".equals(value) && code != 0 && code != 2 ? 2 : 0));
            }
        }
        int[] seen = {-1};
        RoydOciNetwork publisher = new RoydOciNetwork(new Context(), index -> seen[0]=index);
        publisher.updateMeteredInterface(42); check(seen[0] == 42);
        publisher.updateMeteredInterface(0); check(seen[0] == 0);
        publisher.mMeteredInterface = index -> { throw new IllegalStateException("map failure"); };
        try { publisher.updateMeteredInterface(42); throw new AssertionError(); }
        catch (IOException expected) { check(expected.getCause() instanceof IllegalStateException); }
        java.lang.System.out.println("OCI network gate, singleton and metered callback contracts passed");
    }
}
JAVA
  "$ROYD_TEST_JAVA_HOME/bin/javac" -d "$tmp" "$tmp/RoydOciNetwork.java"
  "$ROYD_TEST_JAVA_HOME/bin/java" -cp "$tmp" RoydOciNetwork
else
  printf '%s\n' 'Java execution skipped: set ROYD_TEST_JAVA_HOME for OCI parsing contracts'
fi
printf '%s\n' 'Android 15 OCI network publication contract passed'
