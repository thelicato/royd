#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
patch="$root/android/patches/android-15.0.0_r36/0059-netpolicy-skip-unadvertised-container-wifi.patch"
[ "$(grep -c '^diff --git ' "$patch")" -eq 1 ]
[ "$(grep -c '^-[^-]' "$patch")" -eq 1 ]
! grep -Eq '^\+.*(Log\.|Slog\.|setRestrictBackground|setUidPolicy|catch.*RuntimeException)' "$patch"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
target=frameworks/base/services/core/java/com/android/server/net/NetworkPolicyManagerShellCommand.java
mkdir -p "$tmp/$(dirname "$target")"
# Pinned upstream constructor and complete listing method. Apply the real patch,
# then execute its decisions, rather than reimplementing its gate in the test.
cat >"$tmp/$target" <<'JAVA'

import android.content.Context;
import android.net.NetworkPolicyManager;
import android.net.wifi.WifiConfiguration;

    private final NetworkPolicyManagerService mInterface;
    private final WifiManager mWifiManager;

    NetworkPolicyManagerShellCommand(Context context, NetworkPolicyManagerService service) {
        mInterface = service;
        mWifiManager = (WifiManager) context.getSystemService(Context.WIFI_SERVICE);
    }

    @Override
    public int onCommand(String cmd) { return 0; }

    private int listWifiNetworks() {
        final PrintWriter pw = getOutPrintWriter();
        final String arg = getNextArg();
        final int match;
        if (arg == null) {
            match = WifiConfiguration.METERED_OVERRIDE_NONE;
        } else if (Boolean.parseBoolean(arg)) {
            match = WifiConfiguration.METERED_OVERRIDE_METERED;
        } else {
            match = WifiConfiguration.METERED_OVERRIDE_NOT_METERED;
        }

        final List<WifiConfiguration> configs = mWifiManager.getConfiguredNetworks();
        for (WifiConfiguration config : configs) {
            if (arg == null || config.meteredOverride == match) {
                pw.print(NetworkPolicyManager.resolveNetworkId(config));
                pw.print(';');
                pw.println(overrideToString(config.meteredOverride));
            }
        }
        return 0;
    }
JAVA
(cd "$tmp" && patch --batch --fuzz=0 -p1 <"$patch")
source=${ROYD_ANDROID15_NETPOLICY_SOURCE:-$tmp/$target}
if [ -z "${ROYD_TEST_JAVA_HOME:-}" ]; then
  printf '%s\n' 'Java execution skipped: set ROYD_TEST_JAVA_HOME for netpolicy contracts'
  exit 0
fi
cat >"$tmp/NetworkPolicyManagerShellCommand.java" <<'JAVA'
import java.io.PrintWriter;
import java.io.StringWriter;
import java.util.List;
class NetworkPolicyManagerShellCommand {
JAVA
awk '
  /private final NetworkPolicyManagerService mInterface;/ { print }
  /private final WifiManager mWifiManager;/ { print }
  /private final boolean mSkipRoydWifi;/ { print }
  /private static boolean shouldSkipRoydWifi\(/ { copy=1 }
  /^    NetworkPolicyManagerShellCommand\(/ { copy=1 }
  /private int listWifiNetworks\(/ { copy=1 }
  copy { print }
  copy && /^    }/ { copy=0 }
' "$source" >>"$tmp/NetworkPolicyManagerShellCommand.java"
cat >>"$tmp/NetworkPolicyManagerShellCommand.java" <<'JAVA'
    static String marker;
    static int errno, probes, lookups, reads;
    static boolean feature, failLookup, failRead, nullManager;
    String argument;
    StringWriter output = new StringWriter();
    PrintWriter getOutPrintWriter() { return new PrintWriter(output); }
    String getNextArg() { return argument; }
    static String overrideToString(int value) {
        return value == 1 ? "true" : value == 2 ? "false" : "none";
    }
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
            return nullManager ? null : new WifiManager();
        }
    }
    static class NetworkPolicyManagerService {}
    static class NetworkPolicyManager {
        static String resolveNetworkId(WifiConfiguration config) { return config.name; }
    }
    static class WifiConfiguration {
        static final int METERED_OVERRIDE_NONE=0, METERED_OVERRIDE_METERED=1,
                METERED_OVERRIDE_NOT_METERED=2;
        final int meteredOverride;
        final String name;
        WifiConfiguration(int value) { meteredOverride=value; name="network" + value; }
    }
    static class WifiManager {
        List<WifiConfiguration> getConfiguredNetworks() {
            reads++;
            if (failRead) throw new SecurityException("permission denied");
            return List.of(new WifiConfiguration(0), new WifiConfiguration(1),
                    new WifiConfiguration(2));
        }
    }
    static void check(boolean value) { if (!value) throw new AssertionError(); }
    public static void main(String[] args) {
        int cases=0;
        for (String value : new String[] {null, "", "0", "true", "1"})
        for (int code : new int[] {0, 2, 5, 13})
        for (boolean advertised : new boolean[] {false, true}) {
            marker=value; errno=code; feature=advertised; probes=lookups=reads=0;
            failLookup=failRead=nullManager=false;
            boolean skip="1".equals(value) && !feature && errno == 2;
            NetworkPolicyManagerService service = new NetworkPolicyManagerService();
            NetworkPolicyManagerShellCommand shell =
                    new NetworkPolicyManagerShellCommand(new Context(), service);
            check(shell.mInterface == service);
            check(shell.mSkipRoydWifi == skip);
            check(lookups == (skip ? 0 : 1));
            check(probes == ("1".equals(value) && !feature ? 1 : 0));
            for (String filter : new String[] {null, "true", "false"}) {
                shell.argument=filter; shell.output=new StringWriter();
                check(shell.listWifiNetworks() == 0);
                String expected = skip ? "" : filter == null
                        ? "network0;none\nnetwork1;true\nnetwork2;false\n"
                        : filter.equals("true") ? "network1;true\n" : "network2;false\n";
                check(shell.output.toString().equals(expected));
            }
            check(reads == (skip ? 0 : 3));
            failRead=true;
            boolean threw=false;
            try { shell.listWifiNetworks(); } catch (SecurityException expected) { threw=true; }
            check(threw == !skip);
            failLookup=true; lookups=0; threw=false;
            try { new NetworkPolicyManagerShellCommand(new Context(), service); }
            catch (IllegalStateException expected) { threw=true; }
            check(threw == !skip);
            check(lookups == (skip ? 0 : 1));
            failLookup=failRead=false; nullManager=true; threw=false;
            shell=new NetworkPolicyManagerShellCommand(new Context(), service);
            try { shell.listWifiNetworks(); } catch (NullPointerException expected) { threw=true; }
            check(threw == !skip);
            cases++;
        }
        java.lang.System.out.println("Netpolicy gate/lookup/list/permission/failure contracts passed: " + cases);
    }
}
JAVA
"$ROYD_TEST_JAVA_HOME/bin/javac" -d "$tmp" "$tmp/NetworkPolicyManagerShellCommand.java"
"$ROYD_TEST_JAVA_HOME/bin/java" -cp "$tmp" NetworkPolicyManagerShellCommand
printf '%s\n' 'Android 15 netpolicy Wi-Fi container contract passed'
