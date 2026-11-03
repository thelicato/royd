/*
 * Copyright 2026 The royd Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
import java.util.*;

class SettingsHearingAidControllerTest {
    static String marker;
    static boolean selinux, supported, ready;
    static int mode;
    static Map<String, Integer> calls;
    static void hit(String key) { calls.merge(key, 1, Integer::sum); }
    static void check(boolean value) { if (!value) throw new AssertionError(calls); }
    static class System { static String getenv(String key) {
        check(key.equals("ROYD_CONTAINER")); return marker;
    }}
    static class android { static class os { static class SELinux {
        static boolean isSELinuxEnabled() { return selinux; }
    }}}
    static class PackageManager {
        static final String FEATURE_BLUETOOTH="bt", FEATURE_BLUETOOTH_LE="le";
        int features;
        boolean error;
        boolean hasSystemFeature(String feature) {
            if (error) throw new SecurityException();
            return (features & (feature.equals(FEATURE_BLUETOOTH) ? 1 : 2)) != 0;
        }
    }
    static class Context {
        final PackageManager pm=new PackageManager();
        PackageManager getPackageManager() { return pm; }
        void registerReceiver(Object receiver, IntentFilter filter) { hit("registerReceiver"); }
        void unregisterReceiver(Object receiver) { hit("unregisterReceiver"); }
    }
    static class IntentFilter { void addAction(String action) { hit("filterAction"); } }
    static class BluetoothHearingAid { static final String ACTION_CONNECTION_STATE_CHANGED="asha"; }
    static class BluetoothHapClient { static final String ACTION_HAP_CONNECTION_STATE_CHANGED="hap"; }
    static class BluetoothLeAudio { static final String ACTION_LE_AUDIO_CONNECTION_STATE_CHANGED="le"; }
    static class BluetoothAdapter { static final String ACTION_STATE_CHANGED="adapter"; }
    static class BluetoothProfile { static final int HEARING_AID=21; }
    static class FragmentManager {}
    static class CachedBluetoothDevice {}
    static class Preference {
        final String key;
        Preference(String key) { this.key=key; }
        String getKey() { return key; }
        void setSummary(CharSequence summary) { hit("setSummary"); }
    }
    static class PreferenceScreen {
        Preference findPreference(String key) { hit("findPreference"); return new Preference(key); }
    }
    static class TextUtils { static boolean equals(String a, String b) { return Objects.equals(a,b); } }
    static class ThreadUtils {
        static void postOnBackgroundThread(Runnable task) { hit("backgroundPost"); task.run(); }
        static ThreadUtils getUiThreadHandler() { return new ThreadUtils(); }
        void post(Runnable task) { hit("uiPost"); task.run(); }
    }
    static class EventManager {
        void registerCallback(Object callback) { hit("registerCallback"); }
        void unregisterCallback(Object callback) { hit("unregisterCallback"); }
    }
    static class LocalBluetoothManager {
        LocalBluetoothProfileManager getProfileManager() {
            hit("profileLookup");
            if (mode==3) throw new IllegalStateException();
            return new LocalBluetoothProfileManager();
        }
        EventManager getEventManager() { hit("eventLookup"); return new EventManager(); }
    }
    static class LocalBluetoothProfileManager {
        void addServiceListener(Object listener) { hit("addListener"); }
        void removeServiceListener(Object listener) { hit("removeListener"); }
    }
    static class HearingAidHelper {
        HearingAidHelper(Context context) { hit("helperLookup"); if (mode==4) throw new IllegalStateException(); }
        boolean isHearingAidSupported() { hit("supportedProbe"); return supported; }
        boolean isAllHearingAidRelatedProfilesReady() { hit("readyProbe"); return ready; }
    }
    static class HearingAidUtils {
        static void launchHearingAidPairingDialog(FragmentManager manager, CachedBluetoothDevice device, int metrics) { hit("pairingDialog"); }
    }
    static class com { static class android { static class settings { static class bluetooth { static class Utils {
        static LocalBluetoothManager getLocalBluetoothManager(Context context) {
            hit("managerLookup");
            if (mode==1) throw new IllegalStateException();
            return mode==2 ? null : new LocalBluetoothManager();
        }
    }}}}}
    static class Utils {
        // INSERT_ACTUAL_CAPABILITY_HELPER
    }
    static abstract class Base {
        static final int AVAILABLE=0, UNSUPPORTED_ON_DEVICE=3;
        final Context mContext;
        final String key;
        final Object mHearingAidChangedReceiver=new Object();
        Preference mHearingAidPreference;
        FragmentManager mFragmentManager;
        Base(Context context, String preferenceKey) { mContext=context; key=preferenceKey; }
        String getPreferenceKey() { return key; }
        void displayPreference(PreferenceScreen screen) { hit("displaySuper"); }
        CharSequence loadSummary() { hit("loadSummary"); return "summary"; }
        void launchHearingAidPage() { hit("launchPage"); }
        void updateState(Preference preference) { hit("updateState"); }
        int getMetricsCategory() { return 1; }
        abstract int getAvailabilityStatus();
        abstract void onStart();
        abstract void onStop();
        abstract boolean handlePreferenceTreeClick(Preference preference);
        abstract void refreshSummary(Preference preference);
        abstract void onActiveDeviceChanged(CachedBluetoothDevice device, int profile);
        abstract void onServiceConnected();
        abstract void setFragmentManager(FragmentManager manager);
    }
    // INSERT_ACTUAL_CONTROLLER_CLASSES
    interface Factory { Base create(Context context); }
    static Map<String, Integer> exercise(Context context, Factory factory) {
        calls=new TreeMap<>();
        try {
            Base controller=factory.create(context);
            calls.put("availability",controller.getAvailabilityStatus());
            controller.setFragmentManager(new FragmentManager());
            controller.displayPreference(new PreferenceScreen());
            controller.onStart();
            controller.refreshSummary(null);
            controller.refreshSummary(new Preference("hearing"));
            check(!controller.handlePreferenceTreeClick(new Preference("other")));
            calls.put("click",controller.handlePreferenceTreeClick(new Preference("hearing")) ? 1 : 0);
            controller.onActiveDeviceChanged(null,BluetoothProfile.HEARING_AID);
            controller.onActiveDeviceChanged(new CachedBluetoothDevice(),-1);
            controller.onActiveDeviceChanged(new CachedBluetoothDevice(),BluetoothProfile.HEARING_AID);
            controller.onServiceConnected();
            controller.onStop();
        } catch (RuntimeException error) {
            hit("exception:"+error.getClass().getSimpleName());
        }
        return new TreeMap<>(calls);
    }
    public static void main(String[] args) {
        int cases=0;
        for (String value:new String[]{null,"","0","true","1"})
        for (boolean enabled:new boolean[]{false,true})
        for (int features=0;features<4;features++)
        for (int failure=0;failure<5;failure++)
        for (boolean support:new boolean[]{false,true})
        for (boolean profilesReady:new boolean[]{false,true}) {
            marker=value;selinux=enabled;mode=failure;supported=support;ready=profilesReady;
            Context context=new Context();context.pm.features=features;
            boolean unavailable="1".equals(value)&&!enabled&&features==0;
            Map<String,Integer> actual=exercise(context,c->new Controller(c,"hearing"));
            Map<String,Integer> stock=exercise(context,c->new StockController(c,"hearing"));
            if (unavailable) {
                check(actual.equals(Map.of("availability",3,"click",0,"displaySuper",1,"findPreference",1)));
                check(stock.containsKey("managerLookup"));
                if (failure==2) check(stock.containsKey("exception:NullPointerException"));
            } else check(actual.equals(stock));
            context.pm.error=true;
            Map<String,Integer> metadata=exercise(context,c->new Controller(c,"hearing"));
            if ("1".equals(value)&&!enabled) check(metadata.equals(Map.of("exception:SecurityException",1)));
            else check(metadata.equals(actual));
            cases++;
        }
        java.lang.System.out.println("Actual hearing-aid controller lifecycle, metadata and stock-failure contracts passed: "+cases+" cases");
    }
}
