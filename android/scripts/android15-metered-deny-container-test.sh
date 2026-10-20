#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
patch="$root/android/patches/android-15.0.0_r36/0060-connectivity-enforce-container-metered-deny.patch"
publisher="$root/android/royd/vendor/royd/network/RoydOciNetwork.java"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
[ "$(grep -c '^diff --git ' "$patch")" -eq 3 ]
[ "$(grep -c '^-[^-]' "$patch")" -eq 1 ]
! grep -Eq '^\+.*(setDataSaverEnabled|bandwidthEnableDataSaver|iptables|setUidRule|setFirewallChainEnabled)' "$patch"
grep -Fq 'mContext, mBpfNetMaps::setRoydMeteredInterface);' "$patch"
grep -Fq 'initRoydMeteredDeny();' "$patch"
grep -Fq 'dumpRoydMeteredDeny(pw);' "$patch"
# Compile and execute the actual packet decision from the build-input patch.
cat >"$tmp/policy.c" <<'C'
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#undef __always_inline
#define __always_inline
#define PENALTY_BOX_USER_MATCH 2
#define PENALTY_BOX_ADMIN_MATCH 8192
typedef struct { uint32_t rule; } UidOwnerValue;
static uint32_t selected;
static bool missing_map, missing_uid;
static UidOwnerValue owner;
static uint32_t* bpf_royd_metered_iface_map_lookup_elem(uint32_t* key) {
    assert(*key == 0); return missing_map ? NULL : &selected;
}
static UidOwnerValue* bpf_uid_owner_map_lookup_elem(uint32_t* uid) {
    assert(*uid == 10096); return missing_uid ? NULL : &owner;
}
C
sed -n '/^+static .*royd_metered_uid_blocked(/,/^+}/p' "$patch" | sed 's/^+//' >>"$tmp/policy.c"
cat >>"$tmp/policy.c" <<'C'
int main(void) {
    unsigned cases = 0;
    uint32_t selections[] = {0, 42, UINT32_MAX};
    uint32_t interfaces[] = {1, 42, 43};
    for (unsigned m=0; m<2; m++) for (unsigned u=0; u<2; u++)
    for (unsigned s=0; s<3; s++) for (unsigned i=0; i<3; i++)
    for (unsigned r=0; r<16384; r++) {
        selected=selections[s]; missing_map=m; missing_uid=u; owner.rule=r;
        bool expected = !m && !u && selected && interfaces[i] != 1 &&
            (selected == UINT32_MAX || selected == interfaces[i]) &&
            (r & (PENALTY_BOX_USER_MATCH | PENALTY_BOX_ADMIN_MATCH));
        assert(royd_metered_uid_blocked(interfaces[i], 10096) == expected);
        cases++;
    }
    printf("OCI metered packet decision contracts passed: %u combinations\n", cases);
}
C
${CC:-cc} -std=c11 -O2 -Wall -Wextra -Werror "$tmp/policy.c" -o "$tmp/policy"
"$tmp/policy"
# Keep protocol exceptions after the new deny decision and system exemption before it.
awk '/^ static .*bpf_owner_match\(/ {copy=1}
  copy && /is_system_uid/ {systemLine=NR}
  copy && /royd_metered_uid_blocked\(skb/ {deny=NR}
  copy && /skip_owner_match/ {skip=NR}
  END {exit !(systemLine && deny > systemLine && skip > deny)}' "$patch"
awk '/private void poll\(/ {copy=1}
  copy && /updateMeteredInterface\(iface.getIndex\(\)\)/ {policy=NR}
  copy && /offer\(\);/ {offer=NR}
  END {exit !(policy && offer > policy)}' "$publisher"
if [ -z "${ROYD_TEST_JAVA_HOME:-}" ]; then
  printf '%s\n' 'Java execution skipped: set ROYD_TEST_JAVA_HOME for metered map contracts'
  exit 0
fi
cat >"$tmp/PolicyTest.java" <<'JAVA'
class PolicyTest {
    static final int ENOENT=2;
    static final String TAG="test";
    static String marker;
    static int errno, probes, opens, writes;
    static boolean failOpen, failWrite, failRead;
    static class ErrnoException extends Exception { int errno; ErrnoException(int n){errno=n;} }
    static class Os {
        static void stat(String path) throws ErrnoException {
            check(path.equals("/sys/fs/selinux/enforce")); probes++;
            if (errno != 0) throw new ErrnoException(errno);
        }
    }
    static class System {
        static String getenv(String name) { check(name.equals("ROYD_CONTAINER")); return marker; }
    }
    static class S32 { int val; S32(int n){val=n;} }
    static class U32 { long val; U32(long n){val=n;} }
    static class IBpfMap<K,V> {
        V value;
        void updateEntry(K key, V v) throws ErrnoException {
            check(((S32)key).val == 0); writes++;
            if (failWrite) throw new ErrnoException(5); value=v;
        }
        V getValue(K key) throws ErrnoException {
            if (failRead) throw new ErrnoException(5); return value;
        }
    }
    static class SingleWriterBpfMap {
        static IBpfMap<S32,U32> getSingleton(String path, Class<S32> key, Class<U32> value)
                throws ErrnoException {
            check(path.equals("/sys/fs/bpf/netd_shared/map_netd_royd_metered_iface_map"));
            check(key == S32.class && value == U32.class); opens++;
            if (failOpen) throw new ErrnoException(13); return new IBpfMap<>();
        }
    }
    static class Log { static void i(String tag, String text) {} }
    static class IndentingPrintWriter {
        String output;
        void println(String text) { output=text; }
    }
    static void check(boolean valid) { if (!valid) throw new AssertionError(); }
JAVA
awk '/^diff --git .*\/BpfNetMaps.java / {file=1;next}
  file && /^@@/ {if(copy)exit;copy=1;next}
  copy && /^\+[^+]/ {print substr($0,2)}
  copy && /^\+$/ {print ""}' "$patch" >>"$tmp/PolicyTest.java"
cat >>"$tmp/PolicyTest.java" <<'JAVA'
    public static void main(String[] args) {
        PolicyTest policy = new PolicyTest();
        for (String gate : new String[] {null,"","0","true","1"})
        for (int probe : new int[] {0,2,5,13}) {
            marker=gate; errno=probe; probes=opens=writes=0; sRoydMeteredIfaceMap=null;
            initRoydMeteredDeny();
            boolean enabled="1".equals(gate) && probe == 2;
            check(probes == ("1".equals(gate) ? 1 : 0));
            check(opens == (enabled ? 1 : 0) && writes == opens);
            if (!enabled) {
                try { policy.setRoydMeteredInterface(42); throw new AssertionError(); }
                catch (IllegalStateException expected) {}
                continue;
            }
            check(sRoydMeteredIfaceMap.value.val == 0xffffffffL);
            policy.setRoydMeteredInterface(42); check(sRoydMeteredIfaceMap.value.val == 42);
            for (int invalid : new int[] {-1,1}) {
                int previous=writes;
                try { policy.setRoydMeteredInterface(invalid); throw new AssertionError(); }
                catch (IllegalStateException expected) {check(writes == previous);}
            }
            policy.setRoydMeteredInterface(0); check(sRoydMeteredIfaceMap.value.val == 0xffffffffL);
            failWrite=true;
            try {policy.setRoydMeteredInterface(43); throw new AssertionError();}
            catch (IllegalStateException expected) {check(expected.getCause() instanceof ErrnoException);}
            check(sRoydMeteredIfaceMap.value.val == 0xffffffffL); failWrite=false;
            IndentingPrintWriter out=new IndentingPrintWriter();
            policy.dumpRoydMeteredDeny(out); check(out.output.equals("sRoydMeteredIfaceMap: 4294967295"));
            failRead=true; policy.dumpRoydMeteredDeny(out);
            check(out.output.startsWith("Failed to read OCI metered deny interface:")); failRead=false;
        }
        marker="1"; errno=2;
        for (int failure : new int[] {0,1}) {
            failOpen=failure == 0; failWrite=failure == 1;
            try {initRoydMeteredDeny(); throw new AssertionError();}
            catch (IllegalStateException expected) {check(expected.getCause() instanceof ErrnoException);}
        }
        java.lang.System.out.println("OCI metered gate, map state, failure and dump contracts passed");
    }
}
JAVA
"$ROYD_TEST_JAVA_HOME/bin/javac" -d "$tmp" "$tmp/PolicyTest.java"
"$ROYD_TEST_JAVA_HOME/bin/java" -cp "$tmp" PolicyTest
