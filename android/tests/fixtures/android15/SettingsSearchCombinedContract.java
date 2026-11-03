import java.util.ArrayList;
import java.util.List;

class CombinedSearchControllersTest {
    static String marker;
    static boolean selinux;
    static int codeCalls, xmlCalls, logs;
    static void check(boolean value) { if (!value) throw new AssertionError(); }
    static class System {
        static String getenv(String key) { check(key.equals("ROYD_CONTAINER")); return marker; }
    }
    static class android {
        static class os {
            static class SELinux { static boolean isSELinuxEnabled() { return selinux; } }
        }
    }
    static class PackageManager {
        static final String FEATURE_WIFI = "wifi";
        boolean wifi;
        boolean hasSystemFeature(String feature) { check(feature.equals("wifi")); return wifi; }
    }
    static class Context {
        final PackageManager pm = new PackageManager();
        int flags;
        PackageManager getPackageManager() { return pm; }
    }
    static class AbstractPreferenceController {
        final String key;
        AbstractPreferenceController(String name) { key = name; }
    }
    static class BasePreferenceController extends AbstractPreferenceController {
        BasePreferenceController(String name) { super(name); }
    }
    static class SearchIndexableResource { int xmlResId = 1; }
    static class Log { static void w(String tag, String message) { logs++; } }
    static class PreferenceControllerListHelper {
        static List<BasePreferenceController> getPreferenceControllersFromXml(Context c, int id) {
            xmlCalls++;
            if ((c.flags & 4) != 0) throw new IllegalStateException("XML backend unavailable");
            return List.of(new BasePreferenceController("xml"));
        }
        static List<BasePreferenceController> filterControllers(
                List<BasePreferenceController> xml, List<AbstractPreferenceController> code) {
            return xml;
        }
    }
    static class Utils {
        // INSERT_ACTUAL_HELPER
    }
    static class Base {
        static final String TAG = "BaseSearchIndex";
        List<AbstractPreferenceController> createPreferenceControllers(Context c) {
            codeCalls++;
            if ((c.flags & 1) != 0) throw new IllegalArgumentException("code backend unavailable");
            return (c.flags & 2) != 0 ? null
                    : new ArrayList<>(List.of(new AbstractPreferenceController("code")));
        }
        List<SearchIndexableResource> getXmlResourcesToIndex(Context c, boolean enabled) {
            return (c.flags & 8) != 0 ? null : (c.flags & 16) != 0
                    ? new ArrayList<>() : List.of(new SearchIndexableResource());
        }
        // INSERT_ACTUAL_BASE_ASSEMBLY
    }
    static class OldPhaseOnly extends Base {
        @Override List<AbstractPreferenceController> createPreferenceControllers(Context c) {
            if (Utils.isRoydHardwareUnavailable(c, PackageManager.FEATURE_WIFI)) {
                return new ArrayList<>();
            }
            return super.createPreferenceControllers(c);
        }
    }
    static class Corrected extends Base {
        // INSERT_ACTUAL_COMBINED_OVERRIDE
    }
    static List<Object> outcome(Base value, Context c) {
        codeCalls = xmlCalls = logs = 0;
        Object result;
        try {
            List<AbstractPreferenceController> all = value.getPreferenceControllers(c);
            result = all == null ? "null" : all.stream().map(x -> x.key).toList();
        } catch (RuntimeException failure) {
            result = failure.getClass().getName() + ":" + failure.getMessage();
        }
        return List.of(result, codeCalls, xmlCalls, logs);
    }
    public static void main(String[] args) {
        int cases = 0;
        for (String value : new String[] {null, "", "0", "true", "1"}) {
            for (boolean enabled : new boolean[] {false, true}) {
                for (boolean wifi : new boolean[] {false, true}) {
                    for (int flags = 0; flags < 32; flags++) {
                        marker = value;
                        selinux = enabled;
                        Context c = new Context();
                        c.pm.wifi = wifi;
                        c.flags = flags;
                        boolean unavailable = "1".equals(marker) && !enabled && !wifi;
                        List<Object> actual = outcome(new Corrected(), c);
                        if (unavailable) check(actual.equals(List.of(List.of(), 0, 0, 0)));
                        else check(actual.equals(outcome(new Base(), c)));
                        cases++;
                    }
                }
            }
        }
        marker = "1";
        selinux = false;
        Context c = new Context();
        check(outcome(new OldPhaseOnly(), c).equals(List.of(List.of("xml"), 0, 1, 0)));
        check(outcome(new Corrected(), c).equals(List.of(List.of(), 0, 0, 0)));
        java.lang.System.out.println("Actual code/XML assembly, old failure and stock preservation passed: "
                + cases + " cases");
    }
}
