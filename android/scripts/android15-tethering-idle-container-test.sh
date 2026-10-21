#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
patches=$root/android/patches/android-15.0.0_r36
patch=$patches/0062-tethering-skip-idle-absent-container-hardware.patch
[ "$(grep -c '^diff --git ' "$patch")" -eq 1 ]
! grep -Eq '^\+.*(catch.*(RuntimeException|Exception\))|suppress|setRestrictBackground|mDataSaverEnabled =)' "$patch"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
target=packages/modules/Connectivity/Tethering/src/com/android/networkstack/tethering/Tethering.java
mkdir -p "$tmp/$(dirname "$target")"
cp "$root/android/tests/fixtures/android15/Tethering.java" "$tmp/$target"
patch --batch --fuzz=0 -p1 -d "$tmp" <"$patches/0026-connectivity-skip-absent-container-ethernet-probe.patch" >/dev/null
patch --batch --fuzz=0 -p1 -d "$tmp" <"$patch" >/dev/null
source=${ROYD_ANDROID15_TETHERING_SOURCE:-$tmp/$target}
if [ -z "${ROYD_TEST_JAVA_HOME:-}" ]; then
  printf '%s\n' 'Java execution skipped: set ROYD_TEST_JAVA_HOME for tethering contracts'
  exit 0
fi
cat >"$tmp/TetheringTest.java" <<'JAVA'
import java.util.ArrayList;
import java.util.HashMap;
class TetheringTest {
    static final int TETHERING_WIFI=0, TETHERING_USB=1, TETHERING_NCM=4,
            TETHERING_ETHERNET=5, TETHER_ERROR_NO_ERROR=0;
    static final String TAG="test";
    static String marker;
    static int errno, features, probes, hardwareStops, provisioningStops, markers,
            lookups, releases, ipStops, starts;
    static boolean failLookup, failRelease, failStop, nullManager;
    boolean mRndisEnabled, mNcmEnabled, mRoydIdleHardwareStopLogged;
    final Requests mActiveTetheringRequests=new Requests();
    final States mTetherStates=new States();
    final Context mContext=new Context();
    final Log mLog=new Log();
    final Entitlement mEntitlementMgr=new Entitlement();
    EthernetCallback mEthernetCallback;
    Request mEthernetIfaceRequest;
    String mConfiguredEthernetIface;
    final Object mExecutor=new Object();
    static class Requests extends HashMap<Integer,Object> {}
    static class States extends ArrayList<TetherState> {
        TetherState valueAt(int i){return get(i);}
    }
    static class TetherState {
        final IpServer ipServer;
        TetherState(int type){ipServer=new IpServer(type);}
    }
    static class IpServer {
        final int type;
        IpServer(int value){type=value;}
        int interfaceType(){return type;}
    }
    static class PackageManager {
        static final String FEATURE_WIFI="wifi", FEATURE_USB_HOST="host",
                FEATURE_USB_ACCESSORY="accessory", FEATURE_ETHERNET="ethernet";
        boolean hasSystemFeature(String name) {
            int bit=switch(name){case "wifi"->1;case "host"->2;case "accessory"->4;
                case "ethernet"->8;default->throw new AssertionError(name);};
            return (features&bit)!=0;
        }
    }
    static class Context {
        static final String ETHERNET_SERVICE="ethernet";
        PackageManager getPackageManager(){return new PackageManager();}
        Object getSystemService(String name) {
            check(name.equals(ETHERNET_SERVICE));lookups++;
            if(failLookup)throw new SecurityException("lookup failure");
            return nullManager?null:new EthernetManager();
        }
    }
    static class EthernetCallback {}
    static class EthernetManager {
        Request requestTetheredInterface(Object executor,EthernetCallback callback) {
            check(callback!=null);starts++;return new Request();
        }
    }
    static class Request {
        void release(){releases++;if(failRelease)throw new IllegalStateException("release failure");}
    }
    static class Log {
        void log(String value){check(value.equals("ROYD: skipping idle tethering stops for unadvertised container hardware"));markers++;}
        static void d(String tag,String value){}
    }
    static class Entitlement {void stopProvisioningIfNeeded(int type){provisioningStops++;}}
    void enableTetheringInternal(int type,boolean enable,String iface,Object listener) {
        check(!enable && iface==null && listener==null);
        check(mActiveTetheringRequests.get(type)==null);hardwareStops++;
        if(failStop)throw new IllegalStateException("hardware failure");
    }
    void ensureIpServerStopped(String iface){check(iface.equals("eth-test"));ipStops++;}
    static class System {
        static String getenv(String key){check(key.equals("ROYD_CONTAINER"));return marker;}
    }
    static class android {static class system {
        static class OsConstants {static final int ENOENT=2;}
        static class ErrnoException extends Exception {
            final int errno;
            ErrnoException(int value){errno=value;}
        }
        static class Os {
            static void stat(String path) throws ErrnoException {
                check(path.equals("/sys/fs/selinux/enforce"));probes++;
                if(errno!=0)throw new ErrnoException(errno);
            }
        }
    }}
JAVA
# Execute the actual patched methods, including request/provisioning and Ethernet cleanup.
awk '
  /^    (void stopTetheringInternal|private boolean shouldSkipRoydIdleHardwareStop|private int setEthernetTethering|private void stopEthernetTethering|private boolean isEthernetSupported|private static boolean isRoydContainerWithoutSelinux|private boolean hasSystemFeature)\(/ {copy=1}
  copy {print}
  copy && /^    }/ {copy=0}
' "$source" >>"$tmp/TetheringTest.java"
cat >>"$tmp/TetheringTest.java" <<'JAVA'
    static void check(boolean ok){if(!ok)throw new AssertionError();}
    static void reset() {
        probes=hardwareStops=provisioningStops=markers=lookups=releases=ipStops=starts=0;
        failLookup=failRelease=failStop=nullManager=false;
    }
    public static void main(String[] args) {
        int cases=0;
        for(String value:new String[]{null,"","0","true","1"})
        for(int code:new int[]{0,2,5,13})
        for(int bits=0;bits<16;bits++)
        for(int type:new int[]{0,1,2,4,5,99})
        for(int requested=0;requested<2;requested++)
        for(int ncm=0;ncm<2;ncm++)
        for(int flags=0;flags<4;flags++)
        for(int state:new int[]{-1,0,1,2,4,5,99}) {
            reset();marker=value;errno=code;features=bits;
            TetheringTest test=new TetheringTest();
            test.mRndisEnabled=(flags&1)!=0;test.mNcmEnabled=(flags&2)!=0;
            if(requested!=0)test.mActiveTetheringRequests.put(type,new Object());
            if(ncm!=0)test.mActiveTetheringRequests.put(TETHERING_NCM,new Object());
            if(state>=0)test.mTetherStates.add(new TetherState(state));
            boolean gated="1".equals(value) && code==2;
            boolean pending=requested!=0 || (type==TETHERING_NCM && ncm!=0);
            boolean wifi=type==0 && (bits&1)==0 && state!=0;
            boolean usb=type==1 && (bits&6)==0 && flags==0 && ncm==0 && state!=1 && state!=4;
            boolean skip=gated && !pending && (wifi || usb);
            check(test.shouldSkipRoydIdleHardwareStop(type)==skip);
            test.stopTetheringInternal(type);
            check(test.mActiveTetheringRequests.get(type)==null);
            check(hardwareStops==(skip?0:1) && provisioningStops==1 && markers==(skip?1:0));
            if(skip){test.stopTetheringInternal(type);check(markers==1 && provisioningStops==2);}
            cases++;
        }
        for(String value:new String[]{null,"","0","true","1"})
        for(int code:new int[]{0,2,5,13})
        for(int bits=0;bits<16;bits++)
        for(boolean enable:new boolean[]{false,true})
        for(boolean callback:new boolean[]{false,true})
        for(boolean iface:new boolean[]{false,true}) {
            reset();marker=value;errno=code;features=bits;
            TetheringTest test=new TetheringTest();
            if(callback){test.mEthernetCallback=new EthernetCallback();test.mEthernetIfaceRequest=new Request();}
            if(iface)test.mConfiguredEthernetIface="eth-test";
            boolean unsupported="1".equals(value) && code==2 && (bits&10)==0;
            check(test.isEthernetSupported()==!unsupported && lookups==(unsupported?0:1));
            lookups=0;
            boolean skipLookup=!enable && "1".equals(value) && code==2 && (bits&10)==0;
            check(test.setEthernetTethering(enable)==TETHER_ERROR_NO_ERROR);
            check(lookups==(skipLookup?0:1));
            check(ipStops==(!enable && iface?1:0) && releases==(!enable && callback?1:0));
            check(starts==(enable && !callback?1:0));
            if(!enable)check(test.mConfiguredEthernetIface==null && test.mEthernetCallback==null && test.mEthernetIfaceRequest==null);
            cases++;
        }
        reset();marker="1";errno=2;features=0;
        TetheringTest test=new TetheringTest();
        test.mActiveTetheringRequests.put(TETHERING_WIFI,new Object());failStop=true;
        try{test.stopTetheringInternal(TETHERING_WIFI);throw new AssertionError();}
        catch(IllegalStateException expected){check(hardwareStops==1 && provisioningStops==0 && markers==0);}
        reset();test=new TetheringTest();test.mEthernetCallback=new EthernetCallback();
        test.mEthernetIfaceRequest=new Request();failRelease=true;
        try{test.setEthernetTethering(false);throw new AssertionError();}
        catch(IllegalStateException expected){check(releases==1 && lookups==0 && test.mEthernetCallback!=null);}
        reset();test=new TetheringTest();failLookup=true;marker="0";
        try{test.setEthernetTethering(false);throw new AssertionError();}
        catch(SecurityException expected){check(lookups==1 && releases==0);}
        reset();test=new TetheringTest();nullManager=true;marker="1";
        try{test.setEthernetTethering(true);throw new AssertionError();}
        catch(NullPointerException expected){check(lookups==1 && starts==0);}
        reset();test=new TetheringTest();
        test.mTetherStates.add(new TetherState(99));test.mTetherStates.add(new TetherState(TETHERING_NCM));
        check(!test.shouldSkipRoydIdleHardwareStop(TETHERING_USB));
        test.mTetherStates.add(new TetherState(TETHERING_WIFI));
        check(!test.shouldSkipRoydIdleHardwareStop(TETHERING_WIFI));
        test.stopTetheringInternal(TETHERING_USB);test.stopTetheringInternal(TETHERING_WIFI);
        check(hardwareStops==2 && provisioningStops==2 && markers==0);
        reset();test=new TetheringTest();marker="true";errno=13;
        check(!test.shouldSkipRoydIdleHardwareStop(TETHERING_USB) && probes==0);
        java.lang.System.out.println("Actual patched idle/active/gate and Ethernet cleanup contracts passed: "+cases+" combinations plus failure controls");
    }
}
JAVA
"$ROYD_TEST_JAVA_HOME/bin/javac" -d "$tmp" "$tmp/TetheringTest.java"
"$ROYD_TEST_JAVA_HOME/bin/java" -cp "$tmp" TetheringTest
