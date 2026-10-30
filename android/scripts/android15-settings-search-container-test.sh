#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
patch="$root/android/patches/android-15.0.0_r36/0076-settings-respect-search-capabilities.patch"
# Only imports and two early capability branches may change stock providers.
[ "$(grep -c '^diff --git ' "$patch")" -eq 2 ]
! grep -Eq '^-[^-]|^\+.*(catch |Log\.|ServiceManager|SystemProperties)' "$patch"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
python3 - "$patch" "$tmp" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]).read_text()
blocks=[]
for section in p.split('diff --git ')[1:]:
    additions=[line[1:] for line in section.splitlines() if line.startswith('+') and not line.startswith('+++') and not line.startswith('+import ')]
    blocks.append('\n'.join(additions))
assert len(blocks)==2
wifi,backup=blocks
assert wifi.count('keys.add(')==5 and 'return keys;' in wifi
assert 'return false;' in backup
header='''import java.util.*;
class SearchCapabilityTest {
    static String marker;
    static boolean selinux, failLookup, manufacturer, transport;
    static int wifiLookups, backupLookups;
    static final String PREF_KEY_WIFI_TOGGLE="main_toggle_wifi",
        PREF_KEY_SAVED_NETWORKS="saved_networks", PREF_KEY_ADD_WIFI_NETWORK="add_wifi_network",
        PREF_KEY_CONFIGURE_NETWORK_SETTINGS="configure_network_settings",
        PREF_KEY_DATA_USAGE="non_carrier_data_usage";
    static class System { static String getenv(String key) {
        check(key.equals("ROYD_CONTAINER")); return marker;
    }}
    static class SELinux { static boolean isSELinuxEnabled(){return selinux;} }
    static class PackageManager {
        static final String FEATURE_WIFI="wifi", FEATURE_BACKUP="backup";
        int features;
        boolean hasSystemFeature(String feature) {
            return (features & (feature.equals(FEATURE_WIFI)?1:2))!=0;
        }
    }
    static class Context {
        final PackageManager pm=new PackageManager();
        PackageManager getPackageManager(){return pm;}
    }
    static void check(boolean yes){if(!yes)throw new AssertionError();}
    static List<String> wifi(Context context) {
        List<String> keys=new ArrayList<>(List.of("existing_controller_key"));
'''
mid='''
        wifiLookups++;
        if(failLookup)throw new IllegalStateException("stock Wi-Fi lookup failure");
        return keys;
    }
    static boolean backup(Context context) {
'''
end='''
        backupLookups++;
        if(failLookup)throw new IllegalStateException("stock backup lookup failure");
        return !manufacturer && !transport;
    }
    public static void main(String[] args) {
        for(String value:new String[]{null,"","0","true","1"}) {
            marker=value;
            for(boolean enabled:new boolean[]{false,true}) {
                selinux=enabled;
                for(int features=0;features<4;features++) {
                    Context c=new Context();c.pm.features=features;
                    boolean gated="1".equals(value)&&!enabled;
                    boolean skipWifi=gated&&(features&1)==0, skipBackup=gated&&(features&2)==0;
                    for(boolean failure:new boolean[]{false,true}) {
                        failLookup=failure;wifiLookups=0;backupLookups=0;
                        try {
                            List<String> keys=wifi(c);check(!failure||skipWifi);
                            Set<String> expected=new HashSet<>(List.of("existing_controller_key"));
                            if(skipWifi)expected.addAll(List.of("main_toggle_wifi","saved_networks",
                                "add_wifi_network","configure_network_settings","non_carrier_data_usage"));
                            check(new HashSet<>(keys).equals(expected)&&keys.size()==expected.size());
                        } catch(IllegalStateException e){check(failure&&!skipWifi);}
                        check(wifiLookups==(skipWifi?0:1));
                        for(boolean m:new boolean[]{false,true})for(boolean t:new boolean[]{false,true}) {
                            manufacturer=m;transport=t;backupLookups=0;
                            try {check(backup(c)==(!skipBackup&&!m&&!t));check(!failure||skipBackup);}
                            catch(IllegalStateException e){check(failure&&!skipBackup);}
                            check(backupLookups==(skipBackup?0:1));
                        }
                    }
                }
            }
        }
    }
}
'''
Path(sys.argv[2],'SearchCapabilityTest.java').write_text(header+wifi+mid+backup+end)
PY
if [ -n "${ROYD_TEST_JAVA_HOME:-}" ]; then
  "$ROYD_TEST_JAVA_HOME/bin/javac" -d "$tmp" "$tmp/SearchCapabilityTest.java"
  "$ROYD_TEST_JAVA_HOME/bin/java" -cp "$tmp" SearchCapabilityTest
fi
printf '%s\n' 'Android 15 Settings search capability contracts passed'
