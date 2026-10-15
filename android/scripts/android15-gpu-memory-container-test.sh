#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
patch="$root/android/patches/android-15.0.0_r36/0048-gpuservice-skip-host-global-memory-tracing.patch"
[ "$(grep -c '^diff --git ' "$patch")" -eq 1 ]
grep -Fq 'diff --git a/frameworks/native/services/gpuservice/GpuService.cpp' "$patch"
[ "$(grep -c '^-[^-]' "$patch")" -eq 1 ]
grep -Fqx -- '-            mGpuMem->dump(args, &result);' "$patch"
! grep -Eq '^[+-].*(mGpuWork|mGpuStats|PermissionCache|AID_|detach|join|stop|SetProperty)' "$patch"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
cat >"$tmp/gpu.cpp" <<'CPP'
#include <cassert>
#include <cerrno>
#include <cstring>
#include <memory>
#include <string>
#include <thread>
#include <unistd.h>
static const char* marker;
static int probeError;
static int probes;
static int logs;
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
#define getenv test_getenv
#define access test_access
#define ALOGI(message) do { \
    assert(strcmp(message, "ROYD: not starting host-global GPU memory tracing") == 0); logs++; \
} while (false)
CPP
awk '
  /^\+bool shouldSkipRoydGpuMemoryTracing/ { copy = 1 }
  copy && /^\+/ { print substr($0, 2) }
  copy && /^\+}/ { exit }
' "$patch" >>"$tmp/gpu.cpp"
cat >>"$tmp/gpu.cpp" <<'CPP'
struct Mem {
    int initialisations = 0;
    int dumps = 0;
    void initialize() { initialisations++; }
    void dump(int, std::string* result) { dumps++; result->append("stock GPU memory data"); }
};
struct Tracer {
    int initialisations = 0;
    void initialize(std::shared_ptr<Mem> mem) {
        assert(mem->initialisations == 1);
        initialisations++;
    }
};
struct Service {
    std::shared_ptr<Mem> mGpuMem = std::make_shared<Mem>();
    std::unique_ptr<Tracer> mGpuMemTracer = std::make_unique<Tracer>();
    std::unique_ptr<std::thread> mGpuMemAsyncInitThread;
    void start() {
CPP
awk '
  /^     mGpuMemAsyncInitThread =/ { copy = 1 }
  copy && /^[ +]/ { print substr($0, 2) }
  copy && /^     }\);/ { exit }
' "$patch" >>"$tmp/gpu.cpp"
cat >>"$tmp/gpu.cpp" <<'CPP'
    }
    std::string dump(bool dumpAll, bool dumpMem) {
        std::string result;
        int args = 0;
CPP
awk '
  /^         if \(dumpAll \|\| dumpMem\)/ { copy = 1 }
  copy && /^[ +]/ { print substr($0, 2) }
  copy && /^         }/ { exit }
' "$patch" >>"$tmp/gpu.cpp"
cat >>"$tmp/gpu.cpp" <<'CPP'
        return result;
    }
};
int main() {
    const char* markers[] = {nullptr, "", "0", "true", "1"};
    for (const char* value : markers) {
        marker = value;
        for (int error : {0, ENOENT, EACCES, EIO, ENOTDIR}) {
            probeError = error;
            const bool explicitContainer = value && strcmp(value, "1") == 0;
            const bool gated = explicitContainer && error == ENOENT;
            probes = logs = 0;
            assert(shouldSkipRoydGpuMemoryTracing() == gated);
            assert(probes == int(explicitContainer));
            Service service;
            service.start();
            // Even a skipped initialiser leaves the existing destructor a joinable thread.
            assert(service.mGpuMemAsyncInitThread->joinable());
            service.mGpuMemAsyncInitThread->join();
            assert(service.mGpuMem->initialisations == int(!gated));
            assert(service.mGpuMemTracer->initialisations == int(!gated));
            assert(logs == int(gated));
            assert(service.dump(false, false).empty());
            for (bool all : {false, true}) {
                const auto result = service.dump(all, !all);
                assert(result == (gated
                    ? "GPU memory tracing unavailable: host-global accounting is not container-scoped\n\n"
                    : "stock GPU memory data\n"));
            }
            assert(service.mGpuMem->dumps == (gated ? 0 : 2));
            assert(logs == int(gated));
        }
    }
}
CPP
c++ -std=c++17 -pthread -Wall -Wextra -Werror "$tmp/gpu.cpp" -o "$tmp/gpu"
"$tmp/gpu"
printf '%s\n' 'Android 15 GPU-memory tracing container contract passed'
