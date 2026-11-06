/* Copyright 2026 The royd Authors. SPDX-License-Identifier: Apache-2.0 */
import java.util.*;
import java.util.concurrent.Executor;

class SettingsSavedBluetoothControllerTest {
    static String marker;
    static boolean selinux;
    static final List<String> calls = new ArrayList<>();
    static void hit(String call) { calls.add(call); }
    static void check(boolean value) { if (!value) throw new AssertionError(calls); }
    static class System { static String getenv(String key) {
        check(key.equals("ROYD_CONTAINER")); return marker;
    }}
    static class android { static class os { static class SELinux {
        static boolean isSELinuxEnabled() { return selinux; }
    }}}
    @interface VisibleForTesting {}
    interface LifecycleObserver {}
    interface PreferenceControllerMixin {}
    interface OnStart { void onStart(); }
    interface OnStop { void onStop(); }
    interface DevicePreferenceCallback {
        void onDeviceAdded(Preference preference);
        void onDeviceRemoved(Preference preference);
    }
    static class PackageManager {
        static final String FEATURE_BLUETOOTH="bt", FEATURE_BLUETOOTH_LE="le";
        int features;
        boolean error;
        boolean hasSystemFeature(String feature) {
            if (error) throw new SecurityException("feature probe");
            return (features & (feature.equals(FEATURE_BLUETOOTH) ? 1 : 2)) != 0;
        }
    }
    static class Context {
        static final int RECEIVER_EXPORTED_UNAUDITED=2;
        final PackageManager pm=new PackageManager();
        final BluetoothAdapter adapter=new BluetoothAdapter();
        boolean missingAdapter, managerError, dockError, noDock;
        PackageManager getPackageManager() { return pm; }
        <T> T getSystemService(Class<T> kind) {
            check(kind==BluetoothManager.class); hit("bluetoothLookup");
            if (managerError) throw new IllegalStateException("manager probe");
            return kind.cast(new BluetoothManager(this));
        }
        void registerReceiver(Object receiver, IntentFilter filter, int flags) {
            check(flags==RECEIVER_EXPORTED_UNAUDITED); hit("registerReceiver");
        }
        void unregisterReceiver(Object receiver) { hit("unregisterReceiver"); }
        Executor getMainExecutor() { return Runnable::run; }
        String getString(int id) { check(id==1); return "saved devices summary"; }
    }
    static class BluetoothManager {
        final Context context;
        BluetoothManager(Context context) { this.context=context; }
        BluetoothAdapter getAdapter() {
            hit("adapterLookup"); return context.missingAdapter ? null : context.adapter;
        }
    }
    static class BluetoothAdapter {
        static final String ACTION_STATE_CHANGED="adapter";
        boolean enabled;
        boolean isEnabled() { hit("adapterEnabled"); return enabled; }
        List<BluetoothDevice> getMostRecentlyConnectedDevices() { hit("recentDevices"); return List.of(); }
    }
    static class BluetoothDevice {}
    static class CachedBluetoothDevice {
        final BluetoothDevice device=new BluetoothDevice();
        BluetoothDevice getDevice() { return device; }
    }
    static class Intent {}
    static class IntentFilter { IntentFilter(String action) { check(action.equals("adapter")); } }
    abstract static class BroadcastReceiver { public abstract void onReceive(Context c, Intent i); }
    static class Preference {
        String summary="", title="dock";
        boolean visible=true;
        int order;
        void setSummary(String value) { summary=value; }
        String getTitle() { return title; }
        void setOrder(int value) { order=value; }
        void setVisible(boolean value) { visible=value; }
    }
    static class BluetoothDevicePreference extends Preference {
        final CachedBluetoothDevice cached=new CachedBluetoothDevice();
        CachedBluetoothDevice getBluetoothDevice() { return cached; }
    }
    static class PreferenceGroup extends Preference {
        final List<Preference> children=new ArrayList<>();
        final Preference seeAll=new Preference();
        @SuppressWarnings("unchecked") <T extends Preference> T findPreference(String key) {
            check(key.equals("previously_connected_devices_see_all")); return (T)seeAll;
        }
        void addPreference(Preference p) { children.add(p); }
        void removePreference(Preference p) { children.remove(p); }
        void removeAll() { children.clear(); }
        int getPreferenceCount() { return children.size(); }
    }
    static class PreferenceScreen {
        final Context context;
        final PreferenceGroup group=new PreferenceGroup();
        PreferenceScreen(Context context) { this.context=context; }
        @SuppressWarnings("unchecked") <T extends Preference> T findPreference(String key) {
            check(key.equals("previous") || key.equals("saved_device_list")); return (T)group;
        }
        Context getContext() { return context; }
    }
    static class BasePreferenceController {
        static final int AVAILABLE=0, CONDITIONALLY_UNAVAILABLE=2, UNSUPPORTED_ON_DEVICE=3;
        final Context mContext;
        final String key;
        BasePreferenceController(Context context, String key) { mContext=context; this.key=key; }
        String getPreferenceKey() { return key; }
        int getAvailabilityStatus() { return AVAILABLE; }
        boolean isAvailable() { return getAvailabilityStatus()==AVAILABLE; }
        void displayPreference(PreferenceScreen screen) {}
    }
    static class DashboardFragment {
        final Context context;
        DashboardFragment(Context context) { this.context=context; }
        Context getContext() { return context; }
        int getMetricsCategory() { return 77; }
    }
    static class BluetoothDeviceUpdater {
        void setPrefContext(Context context) { hit("bluetoothContext"); }
        void forceUpdate() { hit("bluetoothForce"); }
        void registerCallback() { hit("bluetoothRegister"); }
        void unregisterCallback() { hit("bluetoothUnregister"); }
        void refreshPreference() { hit("bluetoothRefresh"); }
    }
    static class SavedBluetoothDeviceUpdater extends BluetoothDeviceUpdater {
        SavedBluetoothDeviceUpdater(Context context, Object callback, boolean showConnected, int metric) {
            check(metric==77); hit("bluetoothConstruct:"+showConnected);
            // Trap use of hardware that the test context deliberately lacks.
            if (context.missingAdapter) throw new NullPointerException("missing adapter");
        }
    }
    static class DockUpdater {
        void registerCallback() { hit("dockRegister"); }
        void unregisterCallback() { hit("dockUnregister"); }
        void setPreferenceContext(Context context) { hit("dockContext"); }
        void forceUpdate() { hit("dockForce"); }
    }
    static class DockUpdaterFeatureProvider {
        DockUpdater getSavedDockUpdater(Context context, Object callback) {
            hit("dockLookup");
            if (context.dockError) throw new IllegalStateException("dock probe");
            return context.noDock ? null : new DockUpdater();
        }
    }
    static class FeatureFactory {
        static FeatureFactory getFeatureFactory() { return new FeatureFactory(); }
        DockUpdaterFeatureProvider getDockUpdaterFeatureProvider() { return new DockUpdaterFeatureProvider(); }
    }
    static class R { static class string { static final int connected_device_see_all_summary=1; } }
    static class Log {
        static final int DEBUG=3;
        static boolean isLoggable(String tag, int level) { return false; }
        static void d(String tag, String message) {}
    }
    static class Utils {
        // INSERT_ACTUAL_CAPABILITY_HELPER
    }
    // INSERT_ACTUAL_CONTROLLER_CLASSES

    static List<String> exercise(boolean stock, boolean saved, Context context) {
        calls.clear();
        BasePreferenceController controller=saved
                ? (stock ? new StockSaved(context) : new Saved(context))
                : (stock ? new StockPreviously(context,"previous") : new Previously(context,"previous"));
        DashboardFragment fragment=new DashboardFragment(context);
        if (controller instanceof StockSaved c) c.init(fragment);
        if (controller instanceof Saved c) c.init(fragment);
        if (controller instanceof StockPreviously c) c.init(fragment);
        if (controller instanceof Previously c) c.init(fragment);
        check(controller.getAvailabilityStatus()==BasePreferenceController.AVAILABLE);
        PreferenceScreen screen=new PreferenceScreen(context);
        controller.displayPreference(screen);
        ((OnStart)controller).onStart();
        // Keep the independent dock callback path active in both controllers.
        Preference dock=new Preference();
        ((DevicePreferenceCallback)controller).onDeviceAdded(dock);
        ((DevicePreferenceCallback)controller).onDeviceRemoved(dock);
        ((OnStop)controller).onStop();
        return new ArrayList<>(calls);
    }
    static List<String> dockCalls(List<String> source) {
        return source.stream().filter(s -> s.startsWith("dock")).toList();
    }
    static String failure(boolean stock, boolean saved, Context context) {
        try { exercise(stock,saved,context); return "none"; }
        catch (NullPointerException | IllegalStateException e) { return e.getClass().getName()+":"+e.getMessage(); }
    }
    public static void main(String[] args) {
        int cases=0;
        for (String env : new String[]{null,"","0","1","true"}) {
            marker=env;
            for (boolean enforcing : new boolean[]{false,true}) {
                selinux=enforcing;
                for (int features=0;features<4;features++) {
                    for (boolean enabled : new boolean[]{false,true}) {
                        for (boolean saved : new boolean[]{false,true}) {
                            Context context=new Context(); context.pm.features=features; context.adapter.enabled=enabled;
                            List<String> old=exercise(true,saved,context);
                            List<String> fresh=exercise(false,saved,context);
                            boolean gated="1".equals(marker) && !selinux && features==0;
                            if (gated) {
                                check(fresh.stream().noneMatch(s -> s.startsWith("bluetooth") || s.startsWith("adapter") || s.equals("recentDevices") || s.endsWith("Receiver")));
                                check(dockCalls(fresh).equals(dockCalls(old)));
                            } else check(fresh.equals(old));
                            ++cases;
                        }
                    }
                }
            }
        }
        marker="1";selinux=false;
        for (boolean saved : new boolean[]{false,true}) {
            Context absent=new Context();absent.missingAdapter=true;
            check(failure(true,saved,absent).startsWith("java.lang.NullPointerException"));
            exercise(false,saved,absent);
            for (int features=1;features<4;features++) {
                absent.pm.features=features;
                check(failure(false,saved,absent).equals(failure(true,saved,absent)));
            }
            absent.pm.features=0;selinux=true;
            check(failure(false,saved,absent).equals(failure(true,saved,absent)));
            selinux=false; marker="0";
            check(failure(false,saved,absent).equals(failure(true,saved,absent)));
            marker="1";
            Context brokenDock=new Context();brokenDock.dockError=true;
            check(failure(false,saved,brokenDock).equals(failure(true,saved,brokenDock)));
            Context brokenManager=new Context();brokenManager.pm.features=1;brokenManager.managerError=true;
            check(failure(false,saved,brokenManager).equals(failure(true,saved,brokenManager)));
        }
        java.lang.System.out.println("Actual saved-device controllers passed: "+cases+" lifecycle/feature cases, missing-hardware regression and preserved failures");
    }
}
