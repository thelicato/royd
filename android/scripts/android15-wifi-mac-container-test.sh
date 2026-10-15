#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
patch="$root/android/patches/android-15.0.0_r36/0049-settings-skip-unadvertised-wifi-mac-lookup.patch"
[ "$(grep -c '^diff --git ' "$patch")" -eq 1 ]
grep -Fq 'diff --git a/frameworks/base/packages/SettingsLib/src/com/android/settingslib/deviceinfo/AbstractWifiMacAddressPreferenceController.java' "$patch"
[ "$(grep -c '^-[^-]' "$patch")" -eq 1 ]
grep -Fxq -- '-        mWifiManager = context.getSystemService(WifiManager.class);' "$patch"
! grep -Eq '^\+.*(catch |Log\.|Slog\.|SystemProperties|ServiceManager|getFactoryMacAddresses|setSummary|Permission)' "$patch"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
if [ -n "${ROYD_TEST_JAVA_HOME:-}" ]; then
  cat >"$tmp/WifiMac.java" <<'JAVA'
class WifiMac {
    static String marker;
    static boolean selinux, failLookup;
    static int lookups, featureQueries, parentCalls;
    static Context parentContext;
    static Lifecycle parentLifecycle;
    static void check(boolean value) { if (!value) throw new AssertionError(); }
    static class System {
        static String getenv(String name) {
            check(name.equals("ROYD_CONTAINER"));
            return marker;
        }
    }
    static class SELinux { static boolean isSELinuxEnabled() { return selinux; } }
    static class PackageManager {
        static final String FEATURE_WIFI = "wifi";
        boolean wifi;
        boolean hasSystemFeature(String name) {
            check(name.equals(FEATURE_WIFI));
            featureQueries++;
            return wifi;
        }
    }
    static class WifiManager {}
    static class Lifecycle {}
    static class Context {
        final PackageManager pm = new PackageManager();
        WifiManager manager;
        PackageManager getPackageManager() { return pm; }
        <T> T getSystemService(Class<T> type) {
            check(type == WifiManager.class);
            lookups++;
            if (failLookup) throw new IllegalStateException();
            return type.cast(manager);
        }
    }
    static class Parent {
        Parent(Context context, Lifecycle lifecycle) {
            parentCalls++;
            parentContext = context;
            parentLifecycle = lifecycle;
        }
        public boolean isAvailable() { throw new AssertionError(); }
    }
    static class AbstractWifiMacAddressPreferenceController extends Parent {
        private final WifiManager mWifiManager;
JAVA
  awk '
    /^     public AbstractWifiMacAddressPreferenceController\(/ { copy = 1 }
    copy && /^     public boolean isAvailable/ { available = 1 }
    copy && /^[ +]/ { print substr($0, 2) }
    available && /^     }/ { exit }
  ' "$patch" >>"$tmp/WifiMac.java"
  cat >>"$tmp/WifiMac.java" <<'JAVA'
    }
    public static void main(String[] args) {
        for (String value : new String[] {null, "", "0", "true", "1"}) {
            marker = value;
            for (boolean enabled : new boolean[] {false, true}) {
                selinux = enabled;
                for (boolean wifi : new boolean[] {false, true}) {
                    for (boolean present : new boolean[] {false, true}) {
                        for (boolean failure : new boolean[] {false, true}) {
                            for (boolean observed : new boolean[] {false, true}) {
                                boolean gated = "1".equals(value) && !enabled;
                                boolean skip = gated && !wifi;
                                Context context = new Context();
                                context.pm.wifi = wifi;
                                context.manager = present ? new WifiManager() : null;
                                Lifecycle lifecycle = observed ? new Lifecycle() : null;
                                failLookup = failure;
                                lookups = featureQueries = parentCalls = 0;
                                try {
                                    var controller = new AbstractWifiMacAddressPreferenceController(
                                            context, lifecycle);
                                    check(skip || !failure);
                                    check(controller.isAvailable() == (!skip && present));
                                } catch (IllegalStateException expected) {
                                    check(!skip && failure);
                                }
                                check(lookups == (skip ? 0 : 1));
                                check(featureQueries == (gated ? 1 : 0));
                                check(parentCalls == 1 && parentContext == context
                                        && parentLifecycle == lifecycle);
                            }
                        }
                    }
                }
            }
        }
    }
}
JAVA
  "$ROYD_TEST_JAVA_HOME/bin/javac" -d "$tmp" "$tmp/WifiMac.java"
  "$ROYD_TEST_JAVA_HOME/bin/java" -cp "$tmp" WifiMac
fi
printf '%s\n' 'Android 15 Wi-Fi MAC container contract passed'
