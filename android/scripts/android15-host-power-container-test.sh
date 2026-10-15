#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
patch="$root/android/patches/android-15.0.0_r36/0044-suspend-isolate-host-kernel-wake-locks.patch"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

[ "$(grep -c '^diff --git ' "$patch")" -eq 4 ]
grep -Fq 'bool useSuspendCounter = true, bool disableKernelWakeLocks = false);' "$patch"
grep -Fq '+      mDisableKernelWakeLocks(disableKernelWakeLocks),' "$patch"
grep -Fq '+      mUseSuspendCounter(useSuspendCounter || disableKernelWakeLocks),' "$patch"
grep -Fq '+        disableHostSuspend);' "$patch"
grep -Fq '+    if (!mDisableKernelWakeLocks && !WriteStringToFd(kZygoteKernelWakelock, mWakeUnlockFd)) {' "$patch"
# Keep native wake-lock accounting, Binder tokens, autosuspend and stock write errors intact.
[ "$(grep -c '^-[^-]' "$patch")" -eq 5 ]
! grep -Eq '^\+.*(mSuspendCounter[+-]|mAutosuspendEnabled|mAutosuspendClientTokens)' "$patch"
grep -Fq 'if (auto result = WriteFile(args[1], args[2]); !result.ok()) {' "$patch"

cat >"$tmp/power.cpp" <<'CPP'
#include <cassert>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>
static const char* marker;
static int selinux;
static int logs;
static int writes;
static bool write_ok;
static const char* test_getenv(const char* name) {
    assert(strcmp(name, "ROYD_CONTAINER") == 0);
    return marker;
}
static int is_selinux_enabled() { return selinux; }
#define getenv test_getenv
struct Sink { Sink& operator<<(const char*) { return *this; } };
#define LOG(level) (logs++, Sink{})
CPP
awk '
  /^\+static bool ShouldSkipRoydHostPowerWrite/ { copy = 1 }
  copy && /^\+/ { print substr($0, 2) }
  copy && /^\+}/ { exit }
' "$patch" >>"$tmp/power.cpp"
cat >>"$tmp/power.cpp" <<'CPP'
struct Result { bool ok = true; };
static Result doWrite(const std::vector<std::string>& args) {
CPP
awk '
  /^ static Result<void> do_write/ { copy = 1 }
  copy && /^\+/ { print substr($0, 2) }
  copy && /^\+    }/ { exit }
' "$patch" >>"$tmp/power.cpp"
cat >>"$tmp/power.cpp" <<'CPP'
    writes++;
    return {write_ok};
}
static bool openKernelWakeLocks(bool mDisableKernelWakeLocks) {
CPP
awk '
  /^\+    if \(mDisableKernelWakeLocks\)/ { copy = 1 }
  copy && /^\+/ {
    line = substr($0, 2);
    if (line == "        return;") line = "        return false;";
    print line;
  }
  copy && /^\+    }/ { exit }
' "$patch" >>"$tmp/power.cpp"
cat >>"$tmp/power.cpp" <<'CPP'
    return true;
}
static bool WriteStringToFd(const char*, int) { writes++; return write_ok; }
static bool usesCounter(bool useSuspendCounter, bool disableKernelWakeLocks) {
CPP
sed -n 's/^+      mUseSuspendCounter(\(.*\)),/    return \1;/p' "$patch" >>"$tmp/power.cpp"
cat >>"$tmp/power.cpp" <<'CPP'
}
static bool releaseZygoteLock(bool mDisableKernelWakeLocks) {
    const char* kZygoteKernelWakelock = "zygote_kwl";
    int mWakeUnlockFd = 10;
CPP
sed -n 's/^+\(    if (!mDisableKernelWakeLocks && !WriteStringToFd.*\)$/\1/p' "$patch" >>"$tmp/power.cpp"
cat >>"$tmp/power.cpp" <<'CPP'
        return false;
    }
    return true;
}
int main() {
    const char* paths[] = {"/sys/power/state", "/sys/power/wakeup_count", "/sys/power/wake_lock",
                          "/sys/power/wake_unlock", "/sys/power/wake_locks", "/data/wake_lock",
                          "/sys/power/state/extra", "/sys/power/pm_freeze_timeout", "/proc/sys/x"};
    const char* markers[] = {nullptr, "", "0", "true", "1"};
    for (const char* value : markers) {
        marker = value;
        for (int enabled : {-1, 0, 1, 2}) {
            selinux = enabled;
            bool gated = value && strcmp(value, "1") == 0 && enabled <= 0;
            for (size_t i = 0; i < sizeof(paths) / sizeof(paths[0]); i++) {
                bool skip = gated && i < 4;
                assert(ShouldSkipRoydHostPowerWrite(paths[i]) == skip);
                for (bool success : {false, true}) {
                    write_ok = success;
                    writes = 0;
                    assert(doWrite({"write", paths[i], "zygote_kwl"}).ok == (skip || success));
                    assert(writes == int(!skip));
                }
            }
        }
    }
    assert(logs == 1);
    for (bool disabled : {false, true}) {
        assert(openKernelWakeLocks(disabled) == !disabled);
        for (bool requested : {false, true}) {
            assert(usesCounter(requested, disabled) == (requested || disabled));
        }
        for (bool success : {false, true}) {
            writes = 0;
            write_ok = success;
            assert(releaseZygoteLock(disabled) == (disabled || success));
            assert(writes == int(!disabled));
        }
    }
}
CPP
c++ -std=c++17 -Wall -Wextra -Werror "$tmp/power.cpp" -o "$tmp/power"
"$tmp/power"
printf '%s\n' 'Android 15 host-power container contract passed'
