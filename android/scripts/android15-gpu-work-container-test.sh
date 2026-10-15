#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
patch="$root/android/patches/android-15.0.0_r36/0050-gpuwork-skip-host-global-accounting.patch"
[ "$(grep -c '^diff --git ' "$patch")" -eq 1 ]
grep -Fq 'diff --git a/frameworks/native/services/gpuservice/gpuwork/GpuWork.cpp' "$patch"
! grep -q '^-[^-]' "$patch"
! grep -Eq '^\+.*(detach|stop|join|Permission|AStatsManager|mGpuStats|SetProperty)' "$patch"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
cat >"$tmp/work.cpp" <<'CPP'
#include <atomic>
#include <cassert>
#include <cerrno>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>
#include <unistd.h>
static const char* marker;
static int probeError, probes, failure, sleeps, waits, permissions, maps, attaches;
static int registrations, skipLogs, stockLogs, clearRuns;
static const char* test_getenv(const char* name) {
    assert(strcmp(name, "ROYD_CONTAINER") == 0);
    return marker;
}
static int test_access(const char* path, int mode) {
    assert(strcmp(path, "/sys/fs/selinux/enforce") == 0 && mode == F_OK);
    probes++;
    errno = probeError;
    return probeError ? -1 : 0;
}
static void logMessage(const char* message) {
    if (strcmp(message, "Initialized!") == 0) stockLogs++;
    else {
        assert(strcmp(message, "ROYD: not starting host-global GPU work tracing") == 0);
        skipLogs++;
    }
}
#define getenv test_getenv
#define access test_access
#define ALOGI(message) logMessage(message)
CPP
awk '
  /^\+bool shouldSkipRoydGpuWorkTracing/ { copy = 1 }
  copy && /^\+/ { print substr($0, 2) }
  copy && /^\+}/ { exit }
' "$patch" >>"$tmp/work.cpp"
cat >>"$tmp/work.cpp" <<'CPP'
namespace std::this_thread {
void test_sleep_for(std::chrono::seconds value) {
    assert(value.count() == 30);
    sleeps++;
}
}
namespace bpf { void waitForProgsLoaded() { waits++; } }
namespace android::util { constexpr int GPU_WORK_PER_UID = 10054; }
void AStatsManager_setPullAtomCallback(int32_t atom, void* options, void (*)(), void* cookie) {
    assert(atom == android::util::GPU_WORK_PER_UID && options == nullptr && cookie != nullptr);
    registrations++;
}
bool getBpfMap(const char* path, int*) {
    maps++;
    assert(strcmp(path, maps == 1 ? "/sys/fs/bpf/map_gpuWork_gpu_work_map"
                                 : "/sys/fs/bpf/map_gpuWork_gpu_work_global_data") == 0);
    return maps != failure;
}
using String16 = int;
template<class T> using Vector = std::vector<T>;
struct GpuWork {
    std::atomic<bool> mInitialized = false;
    bool mStatsdRegistered = false;
    std::mutex mMutex;
    int mGpuWorkMap = 0, mGpuWorkGlobalDataMap = 0;
    std::chrono::steady_clock::time_point mPreviousMapClearTimePoint;
    std::thread mMapClearerThread;
    void waitForPermissions() { permissions++; }
    void periodicallyClearMap() { clearRuns++; }
    static void pullAtomCallback() {}
    bool attachTracepoint(const char* path, const char* group, const char* name) {
        assert(strcmp(path, "/sys/fs/bpf/prog_gpuWork_tracepoint_power_gpu_work_period") == 0);
        assert(strcmp(group, "power") == 0 && strcmp(name, "gpu_work_period") == 0);
        attaches++;
        return failure != 3;
    }
    void initialize();
    void dump(const Vector<String16>&, std::string*);
};
#define sleep_for test_sleep_for
CPP
awk '
  /^ void GpuWork::initialize\(/ { copy = 1 }
  copy && /^[ +]/ { print substr($0, 2) }
  copy && /^ }/ { exit }
' "$patch" >>"$tmp/work.cpp"
printf '%s\n' '#undef sleep_for' >>"$tmp/work.cpp"
awk '
  /^ void GpuWork::dump\(/ { copy = 1 }
  copy && /^[ +]/ { print substr($0, 2) }
' "$patch" >>"$tmp/work.cpp"
cat >>"$tmp/work.cpp" <<'CPP'
    result->append("stock GPU work data\n");
}
int main() {
    const char* markers[] = {nullptr, "", "0", "true", "1"};
    for (const char* value : markers) {
        marker = value;
        for (int error : {0, ENOENT, EACCES, EIO, ENOTDIR}) {
            probeError = error;
            const bool explicitContainer = value && strcmp(value, "1") == 0;
            const bool gated = explicitContainer && error == ENOENT;
            probes = 0;
            assert(shouldSkipRoydGpuWorkTracing() == gated);
            assert(probes == int(explicitContainer));
            for (int fail : {0, 1, 2, 3}) {
                failure = fail;
                sleeps = waits = permissions = maps = attaches = registrations = 0;
                skipLogs = stockLogs = clearRuns = 0;
                GpuWork work;
                std::thread initialiser([&]() { work.initialize(); });
                assert(initialiser.joinable());
                initialiser.join();
                if (work.mMapClearerThread.joinable()) work.mMapClearerThread.join();
                const bool success = !gated && fail == 0;
                assert(work.mInitialized.load() == success);
                assert(work.mStatsdRegistered == success);
                assert(sleeps == int(!gated) && waits == int(!gated)
                        && permissions == int(!gated));
                assert(maps == (gated ? 0 : fail == 1 ? 1 : 2));
                assert(attaches == int(!gated && fail != 1 && fail != 2));
                assert(registrations == int(success) && clearRuns == int(success));
                assert(skipLogs == int(gated) && stockLogs == int(success));
                for (bool initialized : {false, true}) {
                    work.mInitialized.store(initialized);
                    std::string result;
                    work.dump({}, &result);
                    assert(result == (gated
                        ? "GPU work tracing unavailable: host-global accounting is not container-scoped\n"
                        : initialized ? "stock GPU work data\n"
                                      : "GPU work information is not available.\n"));
                }
                assert(skipLogs == int(gated));
            }
        }
    }
}
CPP
c++ -std=c++17 -pthread -Wall -Wextra -Werror "$tmp/work.cpp" -o "$tmp/work"
"$tmp/work"
printf '%s\n' 'Android 15 GPU-work tracing container contract passed'
