#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
patch="$root/android/patches/android-15.0.0_r36/0042-memory-events-avoid-host-global-container-tracing.patch"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

[ "$(grep -c '^diff --git ' "$patch")" -eq 2 ]
grep -Fq '+++ b/frameworks/base/services/core/java/com/android/server/am/OomConnection.java' "$patch"
grep -Fq '+++ b/system/memory/lmkd/lmkd.cpp' "$patch"
grep -Fq 'mOomConnectionThread.start();' "$patch"
grep -Fq 'static bool init_memevent_listener_monitoring() {' "$patch"
# Preserve all stock event handling, PSI/vmstat fallback and failure paths. Only add early gates.
! grep -Eq '^-[^-]' "$patch"
! grep -Eq '^\+.*(capabilities|perf_event_paranoid|register_psi|pgscan|noteAppKill)' "$patch"

cat >"$tmp/gate.cpp" <<'CPP'
#include <cassert>
#include <cstring>
#include <unistd.h>
static const char* marker;
static bool selinux;
static int logs;
static int tracing_calls;
static const char* test_getenv(const char* name) {
    assert(strcmp(name, "ROYD_CONTAINER") == 0);
    return marker;
}
static int test_access(const char* path, int mode) {
    assert(strcmp(path, "/sys/fs/selinux/enforce") == 0 && mode == F_OK);
    return selinux ? 0 : -1;
}
#define getenv test_getenv
#define access test_access
#define ALOGI(message) do { assert(strstr(message, "ROYD: using vmstat fallback") != nullptr); logs++; } while (0)
static bool configure() {
CPP
awk '
  /^\+    const char\* royd_container/ { copy = 1 }
  copy && /^\+/ { print substr($0, 2) }
  copy && /^\+    }/ { exit }
' "$patch" >>"$tmp/gate.cpp"
cat >>"$tmp/gate.cpp" <<'CPP'
    tracing_calls++;
    return true;
}
int main() {
    const char* markers[] = {nullptr, "", "0", "true", "1"};
    for (const char* value : markers) {
        for (int enabled = 0; enabled <= 1; enabled++) {
            marker = value;
            selinux = enabled;
            logs = tracing_calls = 0;
            const bool skip = value != nullptr && strcmp(value, "1") == 0 && !selinux;
            assert(configure() == !skip);
            assert(logs == int(skip) && tracing_calls == int(!skip));
        }
    }
}
CPP
c++ -std=c++17 -Wall -Wextra -Werror "$tmp/gate.cpp" -o "$tmp/gate"
"$tmp/gate"

# A supplied JDK also exercises the exact Java gate without requiring AOSP or changing CI's
# existing tool requirements. System and SELinux are mocked inside the generated test class.
if [ -n "${ROYD_TEST_JAVA_HOME:-}" ]; then
  cat >"$tmp/Gate.java" <<'JAVA'
class Gate {
    static String marker;
    static boolean selinux;
    static int logs;
    static int threadStarts;
    static final String TAG = "OomConnection";
    static class System {
        static String getenv(String key) {
            if (!"ROYD_CONTAINER".equals(key)) throw new AssertionError();
            return marker;
        }
    }
    static class SELinux {
        static boolean isSELinuxEnabled() { return selinux; }
    }
    static class Slog {
        static void i(String tag, String message) {
            if (!TAG.equals(tag) || !message.startsWith("ROYD:")) throw new AssertionError();
            logs++;
        }
    }
    static void configure() {
JAVA
  awk '
    /^\+        if \("1".equals/ { copy = 1 }
    copy && /^\+/ { print substr($0, 2) }
    copy && /^\+        }/ { exit }
  ' "$patch" >>"$tmp/Gate.java"
  cat >>"$tmp/Gate.java" <<'JAVA'
        threadStarts++;
    }
    public static void main(String[] args) {
        for (String value : new String[] {null, "", "0", "true", "1"}) {
            for (boolean enabled : new boolean[] {false, true}) {
                marker = value;
                selinux = enabled;
                logs = threadStarts = 0;
                configure();
                boolean skip = "1".equals(value) && !enabled;
                if (logs != (skip ? 1 : 0) || threadStarts != (skip ? 0 : 1)) {
                    throw new AssertionError();
                }
            }
        }
    }
}
JAVA
  "$ROYD_TEST_JAVA_HOME/bin/javac" -d "$tmp" "$tmp/Gate.java"
  "$ROYD_TEST_JAVA_HOME/bin/java" -cp "$tmp" Gate
fi
printf '%s\n' 'Android 15 memory-event container contract passed'
