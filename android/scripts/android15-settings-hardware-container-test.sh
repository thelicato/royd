#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
patch="$root/android/patches/android-15.0.0_r36/0047-settings-skip-unadvertised-container-hardware.patch"
[ "$(grep -c '^diff --git ' "$patch")" -eq 2 ]
[ "$(grep -c '^-[^-]' "$patch")" -eq 1 ]
grep -Fq -- '-        mWifiManager = (WifiManager) context.getSystemService(Context.WIFI_SERVICE);' "$patch"
! grep -Eq '^\+.*(catch |Log\.|Slog\.|SystemProperties|ServiceManager)' "$patch"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
if [ -n "${ROYD_TEST_JAVA_HOME:-}" ]; then
  cat >"$tmp/Hardware.java" <<'JAVA'
class Hardware {
    static String marker;
    static boolean selinux;
    static boolean failLookup;
    static int lookups;
    static class System {
        static String getenv(String name) {
            check(name.equals("ROYD_CONTAINER"));
            return marker;
        }
    }
    static class SELinux { static boolean isSELinuxEnabled() { return selinux; } }
    static class Build { static boolean IS_EMULATOR; }
    static class PackageManager {
        static final String FEATURE_WIFI = "wifi", FEATURE_USB_HOST = "host",
                FEATURE_USB_ACCESSORY = "accessory";
        int features;
        boolean hasSystemFeature(String name) {
            return (features & (name.equals(FEATURE_WIFI) ? 1 : name.equals(FEATURE_USB_HOST) ? 2 : 4)) != 0;
        }
    }
    static class WifiManager {
        int writes;
        void rename() { writes++; }
    }
    static class Context {
        static final String WIFI_SERVICE = "wifi";
        final PackageManager pm = new PackageManager();
        final WifiManager wifi = new WifiManager();
        PackageManager getPackageManager() { return pm; }
        Object getSystemService(String name) {
            check(name.equals(WIFI_SERVICE));
            lookups++;
            if (failLookup) throw new IllegalStateException();
            return wifi;
        }
    }
    static void check(boolean value) { if (!value) throw new AssertionError(); }
    final Context mContext;
    WifiManager mWifiManager;
    Hardware(Context context) {
        mContext = context;
JAVA
  sed -n '/^+        mWifiManager = shouldSkipRoydWifi()/,/^+                : (WifiManager)/s/^+//p' "$patch" >>"$tmp/Hardware.java"
  printf '%s\n' '    }' >>"$tmp/Hardware.java"
  awk '
    /^\+    private boolean shouldSkipRoydWifi/ { copy = 1 }
    copy && /^\+/ { print substr($0, 2) }
    copy && /^\+    }/ { exit }
  ' "$patch" >>"$tmp/Hardware.java"
  printf '%s\n' '    void rename() {' >>"$tmp/Hardware.java"
  awk '
    /^     private void setTetherSsidName/ { copy = 1 }
    copy && /^\+/ { print substr($0, 2) }
    copy && /^\+        }/ { exit }
  ' "$patch" >>"$tmp/Hardware.java"
  cat >>"$tmp/Hardware.java" <<'JAVA'
        mWifiManager.rename();
    }
    static boolean usbProbe(Context context) {
JAVA
  awk '
    /^\+        if \("1".equals/ { copy = 1 }
    copy && /^\+/ { print substr($0, 2) }
    copy && /^\+        }/ { exit }
  ' "$patch" >>"$tmp/Hardware.java"
  cat >>"$tmp/Hardware.java" <<'JAVA'
        lookups++;
        if (failLookup) throw new IllegalStateException();
        return true;
    }
    public static void main(String[] args) {
        for (String value : new String[] {null, "", "0", "true", "1"}) {
            marker = value;
            for (boolean enabled : new boolean[] {false, true}) {
                selinux = enabled;
                for (int features = 0; features < 8; features++) {
                    for (boolean emulator : new boolean[] {false, true}) {
                        Build.IS_EMULATOR = emulator;
                        boolean gated = "1".equals(value) && !enabled;
                        boolean skipWifi = gated && (features & 1) == 0;
                        boolean skipUsb = gated && !emulator && (features & 6) == 0;
                        Context context = new Context();
                        context.pm.features = features;
                        failLookup = false;
                        lookups = 0;
                        Hardware controller = new Hardware(context);
                        check(lookups == (skipWifi ? 0 : 1));
                        controller.rename();
                        check(context.wifi.writes == (skipWifi ? 0 : 1));
                        // A null manager outside the exception must retain stock failure handling.
                        controller.mWifiManager = null;
                        try {
                            controller.rename();
                            check(skipWifi);
                        } catch (NullPointerException expected) { check(!skipWifi); }
                        lookups = 0;
                        check(usbProbe(context) == !skipUsb);
                        check(lookups == (skipUsb ? 0 : 1));
                        failLookup = true;
                        try { new Hardware(context); check(skipWifi); }
                        catch (IllegalStateException expected) { check(!skipWifi); }
                        try { check(!usbProbe(context) && skipUsb); }
                        catch (IllegalStateException expected) { check(!skipUsb); }
                    }
                }
            }
        }
    }
}
JAVA
  "$ROYD_TEST_JAVA_HOME/bin/javac" -d "$tmp" "$tmp/Hardware.java"
  "$ROYD_TEST_JAVA_HOME/bin/java" -cp "$tmp" Hardware
fi
printf '%s\n' 'Android 15 Settings optional-hardware container contract passed'
