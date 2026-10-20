#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
patches=$root/android/patches/android-15.0.0_r36
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
base=packages/modules/Connectivity
mkdir -p "$tmp/$base/bpf/progs" "$tmp/$base/service/src/com/android/server"
cp "$root/android/tests/fixtures/android15/metered-netd.c" "$tmp/$base/bpf/progs/netd.c"
cp "$root/android/tests/fixtures/android15/datasaver-ConnectivityService.java" "$tmp/$base/service/src/com/android/server/ConnectivityService.java"
awk '/^diff --git / && NR>1 {exit} {print}' "$patches/0060-connectivity-enforce-container-metered-deny.patch" | patch --batch --fuzz=0 -p1 -d "$tmp" >/dev/null
awk '/^diff --git / {copy=($0 !~ /BpfNetMaps.java/)} copy {print}' "$patches/0061-connectivity-enforce-container-data-saver.patch" | patch --batch --fuzz=0 -p1 -d "$tmp" >/dev/null
cat >"$tmp/policy.c" <<'C'
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#undef __always_inline
#define __always_inline
#define HAPPY_BOX_MATCH 1
#define PENALTY_BOX_USER_MATCH 2
#define PENALTY_BOX_ADMIN_MATCH 8192
typedef struct { uint32_t rule; } UidOwnerValue;
static uint32_t selected;
static bool missing_map, missing_uid, enabled;
static int saver;
static UidOwnerValue owner;
static uint32_t* bpf_royd_metered_iface_map_lookup_elem(uint32_t* key) {
    assert(*key == 0); return missing_map ? NULL : &selected;
}
static UidOwnerValue* bpf_uid_owner_map_lookup_elem(uint32_t* uid) {
    assert(*uid == 10096); return missing_uid ? NULL : &owner;
}
static bool* bpf_data_saver_enabled_map_lookup_elem(uint32_t* key) {
    assert(*key == 0); return saver < 0 ? NULL : &enabled;
}
C
sed -n '/^static .*royd_metered_uid_blocked(/,/^}/p' "$tmp/$base/bpf/progs/netd.c" >>"$tmp/policy.c"
cat >>"$tmp/policy.c" <<'C'
int main(void) {
    unsigned cases=0;
    uint32_t selections[]={0,42,UINT32_MAX}, interfaces[]={1,42,43};
    for(unsigned m=0;m<2;m++) for(unsigned u=0;u<2;u++)
    for(unsigned s=0;s<3;s++) for(unsigned i=0;i<3;i++)
    for(unsigned r=0;r<16384;r++) for(saver=-1;saver<2;saver++) {
        selected=selections[s]; missing_map=m; missing_uid=u; owner.rule=r; enabled=saver>0;
        unsigned bits=u?0:r;
        bool metered=!m && selected && interfaces[i]!=1 &&
            (selected==UINT32_MAX || selected==interfaces[i]);
        bool expected=metered && ((bits & (2|8192)) || (!(bits & 1) && saver>0));
        assert(royd_metered_uid_blocked(interfaces[i],10096)==expected); cases++;
    }
    printf("OCI Data Saver packet contracts passed: %u combinations\n",cases);
}
C
${CC:-cc} -std=c11 -O2 -Wall -Wextra -Werror "$tmp/policy.c" -o "$tmp/policy"
"$tmp/policy"
if [ -z "${ROYD_TEST_JAVA_HOME:-}" ]; then
  printf '%s\n' 'Java execution skipped: set ROYD_TEST_JAVA_HOME for activation contracts'
  exit 0
fi
cat >"$tmp/ServiceTest.java" <<'JAVA'
class ServiceTest {
    static final String TAG="test";
    static boolean backend, allowed, remoteFailure, legacyResult, mapFailure, track;
    static int permissions, legacyCalls, mapCalls, callbacks;
    static boolean installed;
    static class RemoteException extends Exception {}
    static class ServiceSpecificException extends RuntimeException {}
    static class Log {static void e(String tag,String text){}}
    static class Netd {
        boolean bandwidthEnableDataSaver(boolean enable) throws RemoteException {
            legacyCalls++; if(remoteFailure)throw new RemoteException(); return legacyResult;
        }
    }
    static class Maps {
        boolean usesRoydMeteredPolicy(){return backend;}
        void setDataSaverEnabled(boolean enable) {
            mapCalls++; if(mapFailure)throw new ServiceSpecificException(); installed=enable;
        }
    }
    final Netd mNetd=new Netd(); final Maps mBpfNetMaps=new Maps();
    final Object mBlockedStatusTrackingUids=new Object();
    void enforceNetworkStackOrSettingsPermission(){permissions++;if(!allowed)throw new SecurityException();}
    boolean shouldTrackUidsForBlockedStatusCallbacks(){return track;}
    void updateTrackingUidsBlockedReasons(){callbacks++;}
JAVA
sed '/@RequiresApi/d; /@Override/d' "$tmp/$base/service/src/com/android/server/ConnectivityService.java" >>"$tmp/ServiceTest.java"
cat >>"$tmp/ServiceTest.java" <<'JAVA'
    static void check(boolean ok){if(!ok)throw new AssertionError();}
    public static void main(String[] args) {
        ServiceTest service=new ServiceTest(); int cases=0;
        for(int bits=0;bits<128;bits++) {
            backend=(bits&1)!=0; allowed=(bits&2)!=0; remoteFailure=(bits&4)!=0;
            legacyResult=(bits&8)!=0; mapFailure=(bits&16)!=0; track=(bits&32)!=0;
            boolean enable=(bits&64)!=0;
            permissions=legacyCalls=mapCalls=callbacks=0;installed=!enable;
            boolean failed=false;
            try{service.setDataSaverEnabled(enable);}catch(IllegalStateException|SecurityException e){failed=true;}
            boolean legacyOK=backend || (!remoteFailure && legacyResult);
            boolean reachesMap=allowed && legacyOK;
            check(permissions==1 && legacyCalls==(allowed && !backend?1:0));
            check(mapCalls==(reachesMap?1:0));
            check(failed==(!allowed || !legacyOK || (backend && mapFailure)));
            check(installed==(reachesMap && !mapFailure?enable:!enable));
            check(callbacks==(reachesMap && !mapFailure && track?1:0));cases++;
        }
        System.out.println("OCI/stock activation, permissions, failure and callback contracts passed: "+cases);
    }
}
JAVA
"$ROYD_TEST_JAVA_HOME/bin/javac" -d "$tmp" "$tmp/ServiceTest.java"
"$ROYD_TEST_JAVA_HOME/bin/java" -cp "$tmp" ServiceTest
