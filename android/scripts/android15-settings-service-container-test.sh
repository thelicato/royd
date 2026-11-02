#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
patch="$root/android/patches/android-15.0.0_r36/0078-settings-respect-optional-service-availability.patch"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
python3 - "$root" "$patch" "$tmp" "${ROYD_ANDROID15_SETTINGS_SERVICE_SOURCE:-}" <<'PY'
from pathlib import Path
import re
import sys
root, patch, out = map(Path, sys.argv[1:4])
sys.dont_write_bytecode = True
sys.path.insert(0, str(root / 'android/tests/fixtures/android15'))
from SettingsSearchPatchFixture import method, sources
source = sources(patch, after=True)
if sys.argv[4]:
    source = {name: (Path(sys.argv[4]) / name).read_text() for name in source}
assert len(source) == 11
added = [x[1:] for x in patch.read_text().splitlines() if x.startswith('+') and not x.startswith('+++')]
assert not any(re.search(r'\b(?:catch|Log|Slog|ServiceManager)\b', x) for x in added)
prefix = 'packages/apps/Settings/src/com/android/settings/'
helper = method(source[prefix + 'Utils.java'], 'isRoydHardwareUnavailable')
classes = {
 'development/WifiVerboseLoggingPreferenceController.java': ['WifiVerboseLoggingPreferenceController', 'isAvailable', 'onPreferenceChange', 'updateState', 'onDeveloperOptionsSwitchDisabled'],
 'development/WifiScanThrottlingPreferenceController.java': ['WifiScanThrottlingPreferenceController', 'isAvailable', 'onPreferenceChange', 'updateState', 'onDeveloperOptionsSwitchDisabled'],
 'location/LocationServicesWifiScanningPreferenceController.java': ['LocationServicesWifiScanningPreferenceController', 'getSummary', 'getAvailabilityStatus'],
 'location/WifiScanningPreferenceController.java': ['WifiScanningPreferenceController', 'isAvailable', 'updateState', 'handlePreferenceTreeClick'],
 'location/WifiScanningMainSwitchPreferenceController.java': ['WifiScanningMainSwitchPreferenceController', 'displayPreference', 'getAvailabilityStatus', 'isChecked', 'setChecked', 'onCheckedChanged'],
 'network/AdaptiveConnectivityTogglePreferenceController.java': ['AdaptiveConnectivityTogglePreferenceController', 'getAvailabilityStatus', 'isChecked', 'setChecked'],
}
header = '''import java.util.*;
class HardwareServicesTest {
 static String marker;static boolean selinux;static int mode,lookups,reads,writes,secureWrites;
 static final int AVAILABLE=0,UNSUPPORTED_ON_DEVICE=3,DISABLED_DEPENDENT_SETTING=2;
 static void check(boolean value){if(!value)throw new AssertionError();}
 static class System {static String getenv(String name){check(name.equals("ROYD_CONTAINER"));return marker;}}
 static class android {static class os {static class SELinux {static boolean isSELinuxEnabled(){return selinux;}}}}
 static class PackageManager {
  static final String FEATURE_WIFI="wifi",FEATURE_USB_HOST="usbhost",FEATURE_USB_ACCESSORY="usbaccessory",FEATURE_ETHERNET="ethernet";
  int features;boolean error;
  boolean hasSystemFeature(String key){if(error)throw new SecurityException();int mask=key.equals("wifi")?1:key.equals("usbhost")?2:key.equals("usbaccessory")?4:8;return (features&mask)!=0;}
 }
 static class Resources {boolean scanning=true;boolean getBoolean(int id){return scanning;}}
 static class Context {
  static final String WIFI_SERVICE="wifi";
  final PackageManager pm=new PackageManager();final Resources resources=new Resources();final UserManager user=new UserManager();
  PackageManager getPackageManager(){return pm;}Resources getResources(){return resources;}
  String getString(int id){return "text"+id;}Object getContentResolver(){return this;}
  WifiManager wifi(){lookups++;if(mode==1)throw new IllegalStateException();return mode==2?null:new WifiManager();}
  WifiManager getSystemService(Class<WifiManager> type){return wifi();}Object getSystemService(String key){check(key.equals("wifi"));return wifi();}
 }
 static class WifiManager {
  boolean isScanAlwaysAvailable(){reads++;return true;}boolean isVerboseLoggingEnabled(){reads++;return true;}boolean isScanThrottleEnabled(){reads++;return true;}
  void setScanAlwaysAvailable(boolean v){writes++;}void setVerboseLoggingEnabled(boolean v){writes++;}void setScanThrottleEnabled(boolean v){writes++;}void setWifiScoringEnabled(boolean v){writes++;}
 }
 static class Settings {static class Secure {
  static final String ADAPTIVE_CONNECTIVITY_ENABLED="adaptive";
  static int getInt(Object resolver,String key,int fallback){return 1;}
  static void putInt(Object resolver,String key,int value){secureWrites++;}
 }}
 static class R {static class bool {static int config_show_location_scanning=1;}static class string {static int scanning_status_text_on=1,scanning_status_text_off=2;}}
 static class UserManager {static final String DISALLOW_CONFIG_LOCATION="location";boolean restricted;static UserManager get(Context c){return c.user;}boolean hasUserRestriction(String key){return restricted;}}
 static class Preference {boolean enabled=true;String getKey(){return "wifi_always_scanning";}}
 static class TwoStatePreference extends Preference {boolean checked;void setChecked(boolean v){checked=v;}boolean isChecked(){return checked;}}
 static class CompoundButton {}
 static class MainSwitchPreference extends TwoStatePreference {void addOnSwitchChangeListener(Object v){}void updateStatus(boolean v){checked=v;}}
 static class PreferenceScreen {final MainSwitchPreference pref=new MainSwitchPreference();MainSwitchPreference findPreference(String key){return pref;}}
 static class Base {
  final Context mContext;Preference mPreference=new TwoStatePreference();
  Base(Context c){mContext=c;}Base(Context c,String key){mContext=c;}
  boolean isAvailable(){return true;}String getPreferenceKey(){return "key";}
  void displayPreference(PreferenceScreen s){mPreference=s.pref;}
  void onDeveloperOptionsSwitchDisabled(){mPreference.enabled=false;}
 }
 static class Utils {
'''
body=header+helper+'\n }\n'
for path, methods in classes.items():
    name=methods[0]
    body+=' static class '+name+' extends Base {\n'
    body+=' final WifiManager mWifiManager;final boolean mWifiUnavailable;\n'
    if name=='WifiScanningPreferenceController':body+=' static final String KEY_WIFI_SCAN_ALWAYS_AVAILABLE="wifi_always_scanning";\n'
    if name=='WifiScanningMainSwitchPreferenceController':body+=' static final String KEY_WIFI_SCANNING_SWITCH="wifi_always_scanning_switch";final UserManager mUserManager;\n'
    for name in methods:body+=method(source[prefix+path],name)+'\n'
    body+=' }\n'
body+='''
 interface Action {void run(Context c,boolean unavailable);}
 static void exercise(Context c,boolean unavailable,Action action){
  lookups=reads=writes=secureWrites=0;boolean failed=false;
  try{action.run(c,unavailable);}catch(IllegalStateException e){check(!unavailable&&mode==1);failed=true;}
  catch(NullPointerException e){check(!unavailable&&mode==2);failed=true;}
  check(failed==(!unavailable&&mode!=0));check(lookups==(unavailable?0:1));
  if(unavailable)check(reads==0&&writes==0&&secureWrites==0);
 }
 public static void main(String[] args){
  int cases=0;
  for(String value:new String[]{null,"","0","true","1"})for(boolean enabled:new boolean[]{false,true})for(int features=0;features<16;features++){
   marker=value;selinux=enabled;Context c=new Context();c.pm.features=features;
   boolean gated="1".equals(value)&&!enabled,unavailable=gated&&(features&1)==0;
   check(Utils.isRoydHardwareUnavailable(c,PackageManager.FEATURE_WIFI)==unavailable);
   check(Utils.isRoydHardwareUnavailable(c,PackageManager.FEATURE_USB_HOST,PackageManager.FEATURE_USB_ACCESSORY)==(gated&&(features&6)==0));
   check(Utils.isRoydHardwareUnavailable(c,PackageManager.FEATURE_ETHERNET,PackageManager.FEATURE_USB_HOST)==(gated&&(features&10)==0));
   check(!Utils.isRoydHardwareUnavailable(c)&&!Utils.isRoydHardwareUnavailable(null,PackageManager.FEATURE_WIFI));
   for(int failure=0;failure<3;failure++)for(boolean shown:new boolean[]{false,true})for(boolean restricted:new boolean[]{false,true}){
    mode=failure;c.resources.scanning=shown;c.user.restricted=restricted;
    exercise(c,unavailable,(context,u)->{WifiVerboseLoggingPreferenceController a=new WifiVerboseLoggingPreferenceController(context);check(a.isAvailable()==!u);check(a.onPreferenceChange(new Preference(),true)==!u);a.updateState(new Preference());a.onDeveloperOptionsSwitchDisabled();if(!u)check(writes==2&&reads==1);});
    exercise(c,unavailable,(context,u)->{WifiScanThrottlingPreferenceController a=new WifiScanThrottlingPreferenceController(context);check(a.isAvailable()==!u);check(a.onPreferenceChange(new Preference(),true)==!u);a.updateState(new Preference());a.onDeveloperOptionsSwitchDisabled();if(!u)check(writes==2&&reads==1);});
    exercise(c,unavailable,(context,u)->{LocationServicesWifiScanningPreferenceController a=new LocationServicesWifiScanningPreferenceController(context,"key");check(a.getAvailabilityStatus()==(u||!shown?UNSUPPORTED_ON_DEVICE:AVAILABLE));check((a.getSummary()==null)==u);});
    exercise(c,unavailable,(context,u)->{WifiScanningPreferenceController a=new WifiScanningPreferenceController(context);check(a.isAvailable()==!u);a.updateState(new TwoStatePreference());check(a.handlePreferenceTreeClick(new TwoStatePreference())==!u);if(!u)check(writes==1&&reads==1);});
    exercise(c,unavailable,(context,u)->{WifiScanningMainSwitchPreferenceController a=new WifiScanningMainSwitchPreferenceController(context);a.displayPreference(new PreferenceScreen());check(a.getAvailabilityStatus()==(u||!shown?UNSUPPORTED_ON_DEVICE:restricted?DISABLED_DEPENDENT_SETTING:AVAILABLE));check(a.isChecked()==!u);check(a.setChecked(true)==!u);a.onCheckedChanged(new CompoundButton(),false);if(!u)check(writes==2);});
    exercise(c,unavailable,(context,u)->{AdaptiveConnectivityTogglePreferenceController a=new AdaptiveConnectivityTogglePreferenceController(context,"key");check(a.getAvailabilityStatus()==(u?UNSUPPORTED_ON_DEVICE:AVAILABLE));check(a.isChecked());check(a.setChecked(false)==!u);if(!u)check(writes==1&&secureWrites==1);});
    cases+=6;
   }
   c.pm.error=true;boolean failed=false;
   try{check(!Utils.isRoydHardwareUnavailable(c,PackageManager.FEATURE_WIFI));}catch(SecurityException expected){failed=true;}
   check(failed==gated);
  }
  java.lang.System.out.println("Actual Settings controller gate, unavailable callbacks and stock failures passed: "+cases+" cases");
 }
}
'''
(out/'HardwareServicesTest.java').write_text(body)
# Search builders omit only unavailable backends; inherited XML keys and stock
# supported-hardware calls must remain, rather than swallowing provider errors.
usb=source[prefix+'connecteddevice/usb/UsbDetailsFragment.java']
assert usb.count('Utils.isRoydHardwareUnavailable(context,')==2
assert 'createControllerList(context, new UsbBackend(context), null)' in usb
hotspot=source[prefix+'wifi/tether/WifiTetherSettings.java']
assert hotspot.count('Utils.isRoydHardwareUnavailable(context, PackageManager.FEATURE_WIFI)')==3
assert 'final List<String> keys = super.getNonIndexableKeys(context);' in hotspot
assert 'keys.add(KEY_WIFI_TETHER_SCREEN);' in hotspot
assert 'return buildPreferenceControllers(context, null /* listener */);' in hotspot
configure=source[prefix+'wifi/ConfigureWifiSettings.java']
assert configure.count('Utils.isRoydHardwareUnavailable(context, PackageManager.FEATURE_WIFI)')==2
assert 'return super.createPreferenceControllers(context);' in configure
assert 'PackageManager.FEATURE_ETHERNET, PackageManager.FEATURE_USB_HOST)' in source[prefix+'network/tether/TetherSettings.java']
PY
if [ -n "${ROYD_TEST_JAVA_HOME:-}" ]; then
  "$ROYD_TEST_JAVA_HOME/bin/javac" -d "$tmp" "$tmp/HardwareServicesTest.java"
  "$ROYD_TEST_JAVA_HOME/bin/java" -cp "$tmp" HardwareServicesTest
fi
printf '%s\n' 'Android 15 Settings optional-service contracts passed'
