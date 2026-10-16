#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
patch="$root/android/patches/android-15.0.0_r36/0057-networkmonitor-skip-unadvertised-container-wifi.patch"
[ "$(grep -c '^diff --git ' "$patch")" -eq 1 ]
[ "$(grep -c '^-[^-]' "$patch")" -eq 2 ]
! grep -Eq '^\+.*(Log\.|Slog\.|VALIDATED|mUseHttps|CAPTIVE_PORTAL|catch.*RuntimeException)' "$patch"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
if [ -n "${ROYD_TEST_JAVA_HOME:-}" ]; then
  cat >"$tmp/Monitor.java" <<'JAVA'
class Monitor {
    static String marker;
    static int errno, probes, lookups;
    static boolean feature, failLookup;
    static class System {
        static String getenv(String key) { check(key.equals("ROYD_CONTAINER")); return marker; }
    }
    static class android { static class system {
        static class OsConstants { static final int ENOENT = 2; }
        static class ErrnoException extends Exception {
            final int errno;
            ErrnoException(int code) { errno=code; }
        }
        static class Os {
            static void stat(String path) throws ErrnoException {
                check(path.equals("/sys/fs/selinux/enforce")); probes++;
                if (errno != 0) throw new ErrnoException(errno);
            }
        }
    } }
    static class PackageManager {
        static final String FEATURE_WIFI = "wifi";
        boolean hasSystemFeature(String key) { check(key.equals(FEATURE_WIFI)); return feature; }
    }
    static class Context {
        static final String WIFI_SERVICE = "wifi";
        PackageManager getPackageManager() { return new PackageManager(); }
        Object getSystemService(String key) {
            check(key.equals(WIFI_SERVICE)); lookups++;
            if (failLookup) throw new IllegalStateException("lookup failure");
            return new WifiManager();
        }
    }
    static class WifiInfo {}
    static class WifiManager {
        WifiInfo getConnectionInfo() { return new WifiInfo(); }
    }
    final boolean mSkipRoydWifi;
    final WifiManager mWifiManager;
    Monitor(Context context) {
JAVA
  sed -n '/^+        mSkipRoydWifi =/,/^+                : (WifiManager)/s/^+//p' "$patch" >>"$tmp/Monitor.java"
  printf '%s\n' '    }' '    WifiInfo wifiStats() {' >>"$tmp/Monitor.java"
  sed -n '/^+                final WifiInfo wifiInfo =/s/^+//p' "$patch" >>"$tmp/Monitor.java"
  printf '%s\n' '        return wifiInfo;' '    }' >>"$tmp/Monitor.java"
  awk '/^\+    private static boolean shouldSkipRoydWifi/ { copy=1 }
    copy && /^\+/ { print substr($0, 2) }
    copy && /^\+    }/ { exit }' "$patch" >>"$tmp/Monitor.java"
  cat >>"$tmp/Monitor.java" <<'JAVA'
    static void check(boolean value) { if (!value) throw new AssertionError(); }
    public static void main(String[] args) {
        int cases=0;
        for (String value : new String[] {null, "", "0", "true", "1"})
        for (int code : new int[] {0, 2, 5, 13})
        for (boolean advertised : new boolean[] {false, true}) {
            marker=value; errno=code; feature=advertised; probes=0; lookups=0; failLookup=false;
            boolean skip="1".equals(value) && !feature && errno == 2;
            Monitor monitor=new Monitor(new Context());
            check(monitor.mSkipRoydWifi == skip);
            check(lookups == (skip ? 0 : 1));
            check(probes == ("1".equals(value) && !feature ? 1 : 0));
            check((monitor.wifiStats() == null) == skip);
            failLookup=true; lookups=0;
            boolean threw=false;
            try { new Monitor(new Context()); } catch (IllegalStateException expected) { threw=true; }
            check(threw == !skip);
            check(lookups == (skip ? 0 : 1));
            cases++;
        }
        java.lang.System.out.println("NetworkMonitor Wi-Fi gate/lookup/statistics contracts passed: " + cases);
    }
}
JAVA
  "$ROYD_TEST_JAVA_HOME/bin/javac" -d "$tmp" "$tmp/Monitor.java"
  "$ROYD_TEST_JAVA_HOME/bin/java" -cp "$tmp" Monitor
else
  printf '%s\n' 'Java execution skipped: set ROYD_TEST_JAVA_HOME for NetworkMonitor contracts'
fi
printf '%s\n' 'Android 15 NetworkMonitor Wi-Fi container contract passed'
