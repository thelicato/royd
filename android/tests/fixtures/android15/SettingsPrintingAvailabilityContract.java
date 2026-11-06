/* Copyright 2026 The royd Authors. SPDX-License-Identifier: Apache-2.0 */
import java.util.*;

class SettingsPrintingAvailabilityTest {
    static String marker;
    static boolean selinux, refactor;
    static final List<String> calls=new ArrayList<>();
    static void hit(String call) { calls.add(call); }
    static void check(boolean value) { if (!value) throw new AssertionError(calls); }
    static class System { static String getenv(String key) {
        check(key.equals("ROYD_CONTAINER")); return marker;
    }}
    static class android {
        static class os { static class SELinux { static boolean isSELinuxEnabled() { return selinux; } }}
        static class R { static class id { static final int empty=1; } }
    }
    @interface NonNull {}
    @interface VisibleForTesting {}
    static class PackageManager {
        static final String FEATURE_PRINTING="print";
        boolean printing, error;
        boolean hasSystemFeature(String feature) {
            check(feature.equals(FEATURE_PRINTING));
            if (error) throw new SecurityException("feature probe");
            return printing;
        }
    }
    static class Context {
        final PackageManager pm=new PackageManager();
        boolean restricted, addService, loaderFailure, launchFailure, xmlFailure;
        PackageManager getPackageManager() { return pm; }
    }
    static class Bundle {}
    static class Intent {}
    static class ActivityNotFoundException extends RuntimeException {}
    static class View {
        static final int VISIBLE=0;
        Object parent;
        View getParent() { return (View)parent; }
        @SuppressWarnings("unchecked") <T extends View> T findViewById(int id) {
            if (id==R.id.message) return (T)new TextView();
            check(id==R.id.add_new_service); return (T)new Button();
        }
    }
    static class ViewGroup extends View { void addView(View view) { hit("addEmptyView"); } }
    static class TextView extends View {
        int resource;
        void setText(int id) { resource=id; hit("text:"+id); }
    }
    static class Button extends View {
        void setOnClickListener(Object listener) { hit("addServiceListener"); }
        void setVisibility(int value) { check(value==View.VISIBLE); hit("showAddService"); }
    }
    static class LayoutInflater {
        View inflate(int resource, ViewGroup root, boolean attach) {
            check(resource==R.layout.empty_print_state && !attach); hit("inflatePrintEmpty"); return new View();
        }
    }
    static class PreferenceCategory {}
    static class PreferenceScreen {
        void removeAll() { hit("removeAll"); }
        void removePreference(PreferenceCategory pref) { hit("removeJobsCategory"); }
    }
    static class LoaderManager {
        final Context context;
        LoaderManager(Context context) { this.context=context; }
        void initLoader(int id, Object args, Object controller) {
            hit("loader:"+id);
            // Controlled trap for a dependency that is unavailable in this context.
            // The retained AndroidRuntime stack supplies real crash attribution.
            if (context.loaderFailure) throw new NullPointerException("print manager");
        }
    }
    static class PrintJobsController { PrintJobsController() { hit("jobsController"); } }
    static class PrintServicesController { PrintServicesController() { hit("servicesController"); } }
    static class UserManager { static final String DISALLOW_PRINTING="no_printing"; }
    static class R {
        static class id { static final int message=2, add_new_service=3; }
        static class layout { static final int empty_print_state=4; }
        static class xml { static final int print_settings=5; }
        static class string {
            static final int print_no_services_installed=6, device_info_not_available=7;
        }
    }
    static class Log { static void w(String tag, String text, Throwable error) { hit("activityNotFound"); } }
    static class Flags { static boolean refactorPrintSettings() { return refactor; } }
    static class PrintSettingsPageProvider {
        static final PrintSettingsPageProvider INSTANCE=new PrintSettingsPageProvider();
        String getName() { return "PrintSettings"; }
    }
    static class SpaActivity {
        static void startSpaActivity(Context context, String route) {
            check(route.equals("PrintSettings"));hit("spaRedirect");
        }
    }
    static class BaseFragment {
        static final String TAG="PrintSettingsFragment";
        static final String PRINT_JOBS_CATEGORY="print_jobs_category", PRINT_SERVICES_CATEGORY="print_services_category";
        static final int LOADER_ID_PRINT_JOBS_LOADER=1, LOADER_ID_PRINT_SERVICES=2;
        Context context;
        boolean mIsUiRestricted;
        final TextView empty=new TextView();
        final PreferenceScreen screen=new PreferenceScreen();
        final ViewGroup content=new ViewGroup();
        final View list=new View();
        View emptyView;
        PreferenceCategory mActivePrintJobsCategory, mPrintServicesCategory;
        PrintJobsController mPrintJobsController;
        PrintServicesController mPrintServicesController;
        Button mAddNewServiceButton;
        BaseFragment(String restriction) { check(restriction.equals(UserManager.DISALLOW_PRINTING));hit("restrictionKey");list.parent=content; }
        void onAttach(Context context) { this.context=context;hit("superAttach"); }
        View onCreateView(LayoutInflater inflater, ViewGroup container, Bundle state) { hit("superCreateView");return new View(); }
        void onViewCreated(View view, Bundle state) { hit("superViewCreated"); }
        void onStart() { hit("superStart"); }
        void onClick(View view) {}
        boolean isUiRestricted() { hit("restrictionProbe");return context.restricted; }
        PreferenceScreen getPreferenceScreen() { return screen; }
        PreferenceCategory findPreference(String key) { hit("find:"+key);return new PreferenceCategory(); }
        LoaderManager getLoaderManager() { return new LoaderManager(context); }
        View getListView() { return list; }
        BaseFragment getActivity() { return this; }
        LayoutInflater getLayoutInflater() { return new LayoutInflater(); }
        TextView findViewById(int id) { check(id==android.R.id.empty);hit("existingEmptyView");return empty; }
        void setEmptyView(View view) { emptyView=view;hit("setEmptyView"); }
        Intent createAddNewServiceIntentOrNull() { hit("addServiceIntent");return context.addService ? new Intent() : null; }
        void setHasOptionsMenu(boolean enabled) { check(enabled);hit("printMenu"); }
        void startSubSettingsIfNeeded() { hit("printSubSettings"); }
        void startActivity(Intent intent) { hit("launchServiceSearch");if(context.launchFailure)throw new ActivityNotFoundException(); }
        void finish() { hit("finish"); }
    }
    static class SearchIndexableResource {}
    static class BaseSearchIndexProvider {
        BaseSearchIndexProvider(int id) { check(id==R.xml.print_settings); }
        public List<SearchIndexableResource> getXmlResourcesToIndex(Context context, boolean enabled) {
            hit("xmlResources");if(context.xmlFailure)throw new IllegalStateException("xml failure");return List.of(new SearchIndexableResource());
        }
        protected boolean isPageSearchEnabled(Context context) { hit("pageEnabled");return true; }
    }
    static class Utils {
        // INSERT_ACTUAL_CAPABILITY_HELPER
    }
    // INSERT_ACTUAL_FRAGMENT_CLASSES
    // INSERT_ACTUAL_PROVIDER_CLASSES

    static BaseFragment create(boolean stock) { return stock ? new StockFragment() : new Fragment(); }
    static List<String> exercise(boolean stock, Context context) {
        calls.clear();BaseFragment fragment=create(stock);
        fragment.onAttach(context);
        View view=fragment.onCreateView(new LayoutInflater(),new ViewGroup(),new Bundle());
        fragment.onViewCreated(view,new Bundle());fragment.onStart();
        fragment.onClick(fragment.mAddNewServiceButton);
        return new ArrayList<>(calls);
    }
    static String failure(boolean stock, Context context) {
        try { exercise(stock,context);return "none"; }
        catch(NullPointerException e) { return e.getClass().getName()+":"+e.getMessage(); }
    }
    public static void main(String[] args) {
        int cases=0;
        for(String env:new String[]{null,"","0","1","true"}) for(boolean enforcing:new boolean[]{false,true})
        for(boolean feature:new boolean[]{false,true}) for(boolean routed:new boolean[]{false,true})
        for(boolean restricted:new boolean[]{false,true}) for(boolean configured:new boolean[]{false,true}) {
            marker=env;selinux=enforcing;refactor=routed;
            Context context=new Context();context.pm.printing=feature;context.restricted=restricted;context.addService=configured;
            List<String> old=exercise(true,context),fresh=exercise(false,context);
            boolean unavailable="1".equals(marker)&&!selinux&&!feature;
            if(unavailable) {
                check(fresh.stream().noneMatch(s -> s.startsWith("loader:") || s.endsWith("Controller") || s.startsWith("addService") || s.equals("spaRedirect") || s.equals("finish") || s.equals("printMenu") || s.equals("printSubSettings") || s.equals("launchServiceSearch")));
                if(restricted) check(!fresh.contains("text:7") && !fresh.contains("setEmptyView"));
                else check(fresh.contains("text:7") && fresh.contains("existingEmptyView") && fresh.contains("setEmptyView"));
            } else check(fresh.equals(old));
            calls.clear();BaseSearchIndexProvider provider=new Provider();
            check(provider.getXmlResourcesToIndex(context,true).isEmpty()==unavailable);
            check(provider.isPageSearchEnabled(context)==!unavailable);
            ++cases;
        }
        marker="1";selinux=false;refactor=false;
        Context absent=new Context();absent.loaderFailure=true;
        check(failure(true,absent).startsWith("java.lang.NullPointerException"));
        check(failure(false,absent).equals("none"));
        absent.pm.printing=true;check(failure(false,absent).equals(failure(true,absent)));
        absent.pm.printing=false;selinux=true;check(failure(false,absent).equals(failure(true,absent)));
        selinux=false;marker="0";check(failure(false,absent).equals(failure(true,absent)));
        marker="1";
        for(boolean feature:new boolean[]{false,true}) {
            Context context=new Context();context.pm.printing=feature;context.xmlFailure=true;
            try {
                new Provider().getXmlResourcesToIndex(context,true);check(!feature);
            } catch(IllegalStateException expected) { check(feature); }
            context.addService=true;context.launchFailure=true;
            if(feature) check(exercise(false,context).equals(exercise(true,context)));
        }
        java.lang.System.out.println("Actual Printing methods passed: "+cases+" capability/flag/restriction/action cases, loader trap and preserved failures");
    }
}
