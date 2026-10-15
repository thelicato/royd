#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
patch="$root/android/patches/android-15.0.0_r36/0041-statsd-disable-container-binder-sid-request.patch"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

[ "$(grep -c '^diff --git ' "$patch")" -eq 1 ]
grep -Fq '+++ b/packages/modules/StatsD/statsd/src/main.cpp' "$patch"
grep -Fq 'if (__builtin_available(android __ANDROID_API_U__, *)) {' "$patch"
# Do not change StatsService UID, permission or SID authorisation while disabling transport SIDs.
! grep -Eq '^[-+].*(ENFORCE_|checkSid|checkPermission|AIBinder_getCalling)' "$patch"

cat >"$tmp/gate.cpp" <<'CPP'
#include <cassert>
#include <cstring>
#include <unistd.h>
static const char* marker;
static bool selinux_available;
static int sid_calls;
static bool requested_sid;
static int log_calls;
static const char* test_getenv(const char* name) {
    assert(strcmp(name, "ROYD_CONTAINER") == 0);
    return marker;
}
static int test_access(const char* path, int mode) {
    assert(strcmp(path, "/sys/fs/selinux/enforce") == 0 && mode == F_OK);
    return selinux_available ? 0 : -1;
}
static void AIBinder_setRequestingSid(int binder, bool requested) {
    assert(binder == 1);
    sid_calls++;
    requested_sid = requested;
}
struct Binder { int get() const { return 1; } };
#define getenv test_getenv
#define access test_access
#define ALOGI(message) do { assert(strstr(message, "ROYD: suppressing statsd") != nullptr); log_calls++; } while (0)
CPP
awk '
  /^\+static bool IsRoydContainerWithoutSelinux/ { copy = 1 }
  copy && /^\+/ { print substr($0, 2) }
  copy && /^\+}/ { exit }
' "$patch" >>"$tmp/gate.cpp"
cat >>"$tmp/gate.cpp" <<'CPP'
static void configure(bool api_available) {
    Binder binder;
    if (api_available) {
CPP
awk '
  /^\+        const bool request_sid/ { copy = 1 }
  copy && /^\+/ { print substr($0, 2) }
  copy && /^\+        }/ { exit }
' "$patch" >>"$tmp/gate.cpp"
cat >>"$tmp/gate.cpp" <<'CPP'
    }
}
int main() {
    const char* markers[] = {nullptr, "", "0", "true", "1"};
    for (const char* value : markers) {
        for (bool selinux : {false, true}) {
            marker = value;
            selinux_available = selinux;
            sid_calls = log_calls = 0;
            configure(true);
            const bool skip = value != nullptr && strcmp(value, "1") == 0 && !selinux;
            assert(sid_calls == 1 && requested_sid == !skip && log_calls == int(skip));
            sid_calls = log_calls = 0;
            configure(false);
            assert(sid_calls == 0 && log_calls == 0);
        }
    }
}
CPP
# The executable exercises the actual added gate and registration block for every marker/SELinux
# combination, plus the pre-existing API-availability restriction.
c++ -std=c++17 -Wall -Wextra -Werror -include initializer_list "$tmp/gate.cpp" -o "$tmp/gate"
"$tmp/gate"
printf '%s\n' 'Android 15 statsd Binder SID container contract passed'
