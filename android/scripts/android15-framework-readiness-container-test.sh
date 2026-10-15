#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
patch="$root/android/patches/android-15.0.0_r36/0045-framework-track-service-readiness-across-restarts.patch"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

[ "$(grep -c '^diff --git ' "$patch")" -eq 3 ]
[ "$(grep -c '^-[^-]' "$patch")" -eq 1 ]
grep -Fqx -- '-                && !SystemProperties.getBoolean("sys.boot_completed", false);' "$patch"
[ "$(grep -c '&& !SELinux.isSELinuxEnabled()' "$patch")" -eq 3 ]
grep -Fq 'public SystemServer() {' "$patch"
grep -Fq 'if (phase == SystemService.PHASE_BOOT_COMPLETED) {' "$patch"
grep -Fq '+                        || !SystemProperties.getBoolean("sys.royd.framework_ready", false));' "$patch"
grep -Fq '+            SystemProperties.set("sys.royd.framework_ready", "0");' "$patch"
grep -Fq '+                SystemProperties.set("sys.royd.framework_ready", "1");' "$patch"
! grep -Eq '^\+.*(fetcher\.getService|createService\(ctx\)|catch |set\("sys.boot_completed")' "$patch"

if [ -n "${ROYD_TEST_JAVA_HOME:-}" ]; then
  cat > "$tmp/Readiness.java" <<'JAVA'
class Readiness {
    static final String TAG = "test";
    static String marker;
    static boolean selinux;
    static boolean ready;
    static boolean stockBootCompleted;
    static int writes;
    static int starts;
    static int completions;
    static class System {
        static String getenv(String key) {
            check("ROYD_CONTAINER".equals(key));
            return marker;
        }
    }
    static class SELinux {
        static boolean isSELinuxEnabled() { return selinux; }
    }
    static class SystemProperties {
        static boolean getBoolean(String key, boolean fallback) {
            if ("sys.boot_completed".equals(key)) return stockBootCompleted;
            check("sys.royd.framework_ready".equals(key) && !fallback);
            return ready;
        }
        static void set(String key, String value) {
            check("sys.royd.framework_ready".equals(key));
            check("0".equals(value) || "1".equals(value));
            ready = "1".equals(value);
            writes++;
        }
    }
    static class Slog {
        static void i(String tag, String message) {
            check(TAG.equals(tag));
            if ("ROYD: starting framework service initialisation".equals(message)) starts++;
            else if ("ROYD: framework services initialised".equals(message)) completions++;
            else throw new AssertionError();
        }
    }
    static class SystemService { static final int PHASE_BOOT_COMPLETED = 1000; }
    static void check(boolean value) { if (!value) throw new AssertionError(); }
JAVA
  awk '
    /^     private static boolean shouldSuppressRoydPreBootServiceNotFound/ { copy = 1 }
    copy && /^[ +]/ { print substr($0, 2) }
    copy && /^     }/ { exit }
  ' "$patch" >> "$tmp/Readiness.java"
  printf '%s\n' '    static void begin() {' >> "$tmp/Readiness.java"
  awk '
    /^\+        if \("1".equals/ { copy = 1 }
    copy && /^\+/ { print substr($0, 2) }
    copy && /^\+        }/ { exit }
  ' "$patch" >> "$tmp/Readiness.java"
  cat >> "$tmp/Readiness.java" <<'JAVA'
    }
    static void complete(int phase, boolean failedCallback) {
        if (failedCallback) throw new IllegalStateException("boot callback failed");
JAVA
  awk '
    /^         if \(phase == SystemService.PHASE_BOOT_COMPLETED\)/ {
      print substr($0, 2); copy = 1; next
    }
    copy && /^\+/ { print substr($0, 2) }
    copy && /^\+            }/ { exit }
  ' "$patch" >> "$tmp/Readiness.java"
  cat >> "$tmp/Readiness.java" <<'JAVA'
        }
    }
    public static void main(String[] args) {
        for (String value : new String[] {null, "", "0", "true", "1"}) {
            for (boolean enabled : new boolean[] {false, true}) {
                marker = value;
                selinux = enabled;
                boolean gated = "1".equals(value) && !enabled;
                ready = true;
                stockBootCompleted = true;
                writes = starts = completions = 0;
                for (int lifecycle = 0; lifecycle < 2; lifecycle++) {
                    begin();
                    check(ready == !gated);
                    check(shouldSuppressRoydPreBootServiceNotFound() == gated);
                    for (int phase : new int[] {100, 500, 600}) complete(phase, false);
                    check(ready == !gated);
                    try {
                        complete(1000, true);
                        throw new AssertionError();
                    } catch (IllegalStateException expected) {
                        check(ready == !gated);
                    }
                    complete(1000, false);
                    check(ready && !shouldSuppressRoydPreBootServiceNotFound());
                }
                check(writes == (gated ? 4 : 0));
                check(starts == (gated ? 2 : 0) && completions == (gated ? 2 : 0));
                ready = false;
                check(shouldSuppressRoydPreBootServiceNotFound() == gated);
                ready = true;
                stockBootCompleted = false;
                check(shouldSuppressRoydPreBootServiceNotFound() == gated);
            }
        }
    }
}
JAVA
  "$ROYD_TEST_JAVA_HOME/bin/javac" -d "$tmp" "$tmp/Readiness.java"
  "$ROYD_TEST_JAVA_HOME/bin/java" -cp "$tmp" Readiness
fi
printf '%s\n' 'Android 15 framework-readiness container contract passed'
