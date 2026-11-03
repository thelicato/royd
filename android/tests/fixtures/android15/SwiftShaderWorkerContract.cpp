#include <algorithm>
#include <atomic>
#include <cassert>
#include <cerrno>
#include <cstdarg>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <iostream>
#include <sched.h>
#include <string>
#include <sys/stat.h>
#include <thread>
#include <vector>

#define PROP_VALUE_MAX 92
#define ANDROID_LOG_INFO 4
const char *environment = "1";
const char *property = "true";
int probeError = ENOENT, affinityError = 0, affinityCount = 32;
unsigned logicalCpus = 32;
std::atomic<int> logs{0}, flushCalls{0}, denormalCalls{0};

const char *testGetenv(const char *key) { assert(!strcmp(key, "ROYD_CONTAINER")); return environment; }
int __system_property_get(const char *key, char *value) {
    assert(!strcmp(key, "ro.config.low_ram"));
    strcpy(value, property); return strlen(value);
}
int testStat(const char *path, struct stat *) {
    assert(!strcmp(path, "/sys/fs/selinux/enforce"));
    errno = probeError; return probeError ? -1 : 0;
}
int testAffinity(pid_t pid, size_t size, cpu_set_t *set) {
    assert(pid == 0 && size == sizeof(*set));
    if (affinityError) { errno = affinityError; return -1; }
    CPU_ZERO(set);
    for (int n = 0; n < affinityCount; ++n) CPU_SET(n, set);
    return 0;
}
int __android_log_print(int priority, const char *tag, const char *format, ...) {
    assert(priority == ANDROID_LOG_INFO && !strcmp(tag, "swiftshader"));
    assert(!strcmp(format, "ROYD: low-memory software Vulkan worker budget: %u"));
    va_list args; va_start(args, format); assert(va_arg(args, unsigned) == 4); va_end(args);
    ++logs; return 0;
}

namespace sw {
struct Configuration { uint32_t threadCount = 0; uint64_t affinityMask = 0x55; int affinityPolicy = 7; };
struct CPUID {
    static void setFlushToZero(bool value) { assert(value); ++flushCalls; }
    static void setDenormalsAreZero(bool value) { assert(value); ++denormalCalls; }
};
}
namespace marl {
struct Thread { static unsigned numLogicalCPUs() { return logicalCpus; } };
struct Scheduler {
    struct Config {
        unsigned count = 0; std::pair<uint64_t, int> policy;
        std::function<void(int)> initializer;
        void setWorkerThreadCount(unsigned value) { count = value; }
        void setWorkerThreadAffinityPolicy(std::pair<uint64_t, int> value) { policy = value; }
        void setWorkerThreadInitializer(std::function<void(int)> value) { initializer = value; }
    };
};
}
uint64_t getAffinityFromMask(uint64_t mask) { return mask; }
std::pair<uint64_t, int> getAffinityPolicy(uint64_t mask, int policy) { return {mask, policy}; }

namespace Stock {
using sw::Configuration;
// INSERT_STOCK_CONFIGURATION
}
namespace Patched {
using sw::Configuration;
#define getenv(key) testGetenv(key)
#define stat(path, value) testStat(path, value)
#define sched_getaffinity(pid, size, value) testAffinity(pid, size, value)
// INSERT_CONTAINER_GATE
// INSERT_PATCHED_CONFIGURATION
#undef sched_getaffinity
#undef stat
#undef getenv
}

int main() {
    // Exercise the actual bounded diagnostic's first-use concurrency.
    std::vector<std::thread> threads;
    for (int n = 0; n < 64; ++n) threads.emplace_back([] {
        auto result = Patched::getSchedulerConfiguration(sw::Configuration{});
#ifdef __ANDROID__
        assert(result.count == 4);
#else
        assert(result.count == 16);
#endif
    });
    for (auto &thread : threads) thread.join();
#ifdef __ANDROID__
    assert(logs == 1);
#else
    assert(logs == 0);
#endif
    unsigned cases = 0;
    for (auto env : {static_cast<const char *>(nullptr), "", "0", "1", "true"})
    for (auto prop : {"", "false", "true", "1", "TRUE"})
    for (int error : {0, ENOENT, EACCES, EIO, ENOTDIR, EINTR})
    for (unsigned cpus : {0u, 1u, 2u, 4u, 8u, 16u, 64u})
    for (unsigned explicitCount : {0u, 1u, 4u, 8u, 16u, 64u})
    for (int allowed : {0, 1, 2, 4, 32})
    for (int failure : {0, EINVAL, EACCES}) {
        environment = env; property = prop; probeError = error;
        logicalCpus = cpus; affinityCount = allowed; affinityError = failure;
        sw::Configuration config; config.threadCount = explicitCount;
        auto stock = Stock::getSchedulerConfiguration(config);
        auto actual = Patched::getSchedulerConfiguration(config);
        unsigned expected = stock.count;
#ifdef __ANDROID__
        if (!explicitCount && env && !strcmp(env, "1") && !strcmp(prop, "true") && error == ENOENT) {
            expected = std::min(expected, 4u);
            if (!failure && allowed > 0) expected = std::min(expected, unsigned(allowed));
        }
#endif
        assert(actual.count == expected);
        assert(actual.policy == stock.policy && actual.policy == std::make_pair(config.affinityMask, config.affinityPolicy));
        int before = flushCalls; stock.initializer(0); actual.initializer(0);
        assert(flushCalls == before + 2 && denormalCalls == flushCalls);
        ++cases;
    }
#ifdef __ANDROID__
    assert(logs == 1);
#else
    assert(logs == 0);
#endif
    std::cout << "Actual SwiftShader worker gate, affinity, explicit settings and stock configuration passed: " << cases << " cases plus 64 concurrent calls\n";
}
