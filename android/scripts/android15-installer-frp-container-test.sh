#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
patch="$root/android/patches/android-15.0.0_r36/0054-installer-avoid-absent-container-frp-service.patch"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
target=frameworks/base/services/core/java/com/android/server/pm/PackageInstallerSession.java
mkdir -p "$tmp/tree/$(dirname "$target")"
cp "$root/android/tests/fixtures/android15/PackageInstallerSession.java" "$tmp/tree/$target"
git -C "$tmp/tree" apply --check "$patch"
git -C "$tmp/tree" apply "$patch"
[ "$(grep -c '^diff --git ' "$patch")" -eq 1 ]
[ "$(grep -c '^-[^-]' "$patch")" -eq 1 ]
grep -Fxq -- '-                        mContext.getSystemService(PersistentDataBlockManager.class);' "$patch"
! grep -Eq '^\+.*(catch |Log\.|Slog\.|set\(|isSecureFrpInstallAllowed|SecurityException|return)' "$patch"
if [ -n "${ROYD_TEST_JAVA_HOME:-}" ]; then
  cat >"$tmp/InstallerFrp.java" <<'JAVA'
class InstallerFrp {
    static String marker, store;
    static boolean selinux, enabled, published, managerPresent, active, allowed;
    static int failure, probes, lookups, frpReads, settingReads, allowedChecks, propertyReads;
    static int setting;
    static void check(boolean value) { if (!value) throw new AssertionError(); }
    static class ProbeFailure extends RuntimeException {}
    static class LookupFailure extends RuntimeException {}
    static class FrpFailure extends RuntimeException {}
    static class android { static class security { static class Flags {
        static boolean frpEnforcement() { return enabled; }
    } } }
    static class System {
        static String getenv(String key) { check(key.equals("ROYD_CONTAINER")); return marker; }
    }
    static class SELinux { static boolean isSELinuxEnabled() { return selinux; } }
    static class SystemProperties {
        static String get(String key) { check(key.equals("ro.frp.pst")); propertyReads++; return store; }
    }
    static class ServiceManager {
        static Object checkService(String name) {
            check(name.equals(Context.PERSISTENT_DATA_BLOCK_SERVICE)); probes++;
            if (failure == 1) throw new ProbeFailure();
            return published ? new Object() : null;
        }
    }
    static class PersistentDataBlockManager {
        boolean isFactoryResetProtectionActive() {
            frpReads++;
            if (failure == 3) throw new FrpFailure();
            return active;
        }
    }
    static class Context {
        static final String PERSISTENT_DATA_BLOCK_SERVICE = "persistent_data_block";
        Object getContentResolver() { return this; }
        <T> T getSystemService(Class<T> type) {
            check(type == PersistentDataBlockManager.class); lookups++;
            if (failure == 2) throw new LookupFailure();
            return managerPresent ? type.cast(new PersistentDataBlockManager()) : null;
        }
    }
    static class Global {
        static final String SECURE_FRP_MODE = "secure_frp_mode";
        static int getInt(Object resolver, String key, int fallback) {
            check(resolver != null && key.equals(SECURE_FRP_MODE) && fallback == 0);
            settingReads++; return setting;
        }
    }
    static class Binder { static int getCallingUid() { return 12345; } }
    static boolean isSecureFrpInstallAllowed(Context context, int uid) {
        check(context != null && uid == 12345); allowedChecks++; return allowed;
    }
    static void install() {
        Context mContext = new Context();
JAVA
  cat "$tmp/tree/$target" >>"$tmp/InstallerFrp.java"
  cat >>"$tmp/InstallerFrp.java" <<'JAVA'
    }
    public static void main(String[] args) {
        int cases = 0;
        for (String value : new String[] {null, "", "0", "true", "1"})
        for (boolean se : new boolean[] {false, true})
        for (boolean flag : new boolean[] {false, true})
        for (String path : new String[] {"", "/dev/block/frp"})
        for (boolean service : new boolean[] {false, true})
        for (boolean manager : new boolean[] {false, true})
        for (boolean protection : new boolean[] {false, true})
        for (boolean permit : new boolean[] {false, true})
        for (int legacy : new int[] {0, 1, 2})
        for (int fail = 0; fail < 4; fail++) {
            marker = value; selinux = se; enabled = flag; store = path;
            published = service; managerPresent = manager; active = protection; allowed = permit;
            setting = legacy; failure = fail;
            probes = lookups = frpReads = settingReads = allowedChecks = propertyReads = 0;
            boolean gate = "1".equals(value) && !se;
            boolean probe = flag && gate && path.isEmpty();
            boolean skip = probe && !service;
            boolean lookup = flag && !skip && !(probe && fail == 1);
            boolean read = lookup && manager && fail != 2;
            Class<?> expected = probe && fail == 1 ? ProbeFailure.class
                    : lookup && fail == 2 ? LookupFailure.class
                    : read && fail == 3 ? FrpFailure.class : null;
            boolean secure = flag ? !skip && manager && protection : legacy == 1;
            if (expected == null && secure && !permit) expected = SecurityException.class;
            try { install(); check(expected == null); }
            catch (RuntimeException error) { check(error.getClass() == expected); }
            check(probes == (probe ? 1 : 0));
            check(propertyReads == (flag && gate ? 1 : 0));
            check(lookups == (lookup ? 1 : 0));
            check(frpReads == (read ? 1 : 0));
            check(settingReads == (flag ? 0 : 1));
            boolean errorBeforeDecision = expected == ProbeFailure.class
                    || expected == LookupFailure.class || expected == FrpFailure.class;
            check(allowedChecks == (!errorBeforeDecision && secure ? 1 : 0));
            cases++;
        }
        java.lang.System.out.println("Installer FRP executable cases passed: " + cases);
    }
}
JAVA
  "$ROYD_TEST_JAVA_HOME/bin/javac" -d "$tmp" "$tmp/InstallerFrp.java"
  "$ROYD_TEST_JAVA_HOME/bin/java" -cp "$tmp" InstallerFrp
else
  printf '%s\n' 'Java execution skipped: set ROYD_TEST_JAVA_HOME to enable the FRP decision matrix'
fi
printf '%s\n' 'Android 15 installer FRP container contract passed'
