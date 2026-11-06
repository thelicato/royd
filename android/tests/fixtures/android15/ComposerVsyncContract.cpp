#include <atomic>
#include <cassert>
#include <chrono>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <limits>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <vector>

struct FakeClock {
    using duration = std::chrono::nanoseconds;
    using rep = duration::rep;
    using period = duration::period;
    using time_point = std::chrono::time_point<FakeClock>;
    static constexpr bool is_steady = true;
    static int64_t current;
    static time_point now() { return time_point(duration(current)); }
};
int64_t FakeClock::current;
struct Status {
    bool ok;
    bool isOk() const { return ok; }
    std::string getDescription() const { return "mock callback rejection"; }
};
class ComposerClient;
static void advanceLockClock();
struct FakeMutex {
    bool held = false;
    void lock() {
        if (held) throw std::runtime_error("recursive service lock");
        held = true;
        advanceLockClock();
    }
    void unlock() { held = false; }
    bool try_lock() { if (held) return false; held = true; return true; }
};
struct Callback {
    ComposerClient* client;
    int identity = 0;
    Status onVsync(int64_t display, int64_t timestamp, int32_t period);
};
namespace c3 { using IComposerCallback = Callback; }
class ComposerClient {
  public:
    static constexpr int64_t kDisplayId = 1;
    int32_t mVsyncPeriodNs;
    std::atomic<bool> mVsyncEnabled{true}, mStopVsync{false};
    FakeMutex mMutex;
    std::shared_ptr<Callback> mCallback;
    int64_t nowNanos() const;
    void vsyncLoop();
};
struct Scenario {
    ComposerClient* client;
    int64_t epoch, callbackDelay = 0, oversleep = 0, lockDelay = 0;
    int64_t previousEnd = 0, wake = 0;
    unsigned delivered = 0, sleeps = 0, polls = 0, warnings = 0, limit = 128;
    bool constantCadence = false, failCallback = false;
    bool stopOnWake = false, disableOnWake = false;
    bool replaceOnWake = false;
    int expectedCallback = 0;
    std::vector<int64_t> ticks;
};
static Scenario* active;
static void advanceLockClock() {
    FakeClock::current += active->lockDelay;
    active->wake = FakeClock::current;
}
static void require(bool ok, const char* message) {
    if (!ok) throw std::runtime_error(message);
}
template<class Rep, class Period>
static void sleepFor(std::chrono::duration<Rep, Period> delay) {
    const auto ns = std::chrono::duration_cast<std::chrono::nanoseconds>(delay).count();
    require(ns > 0, "non-positive wait");
    FakeClock::current += ns;
    active->wake = FakeClock::current;
    if (!active->client->mVsyncEnabled.load()) {
        require(++active->polls < 5, "disabled loop did not make progress");
        if (active->polls == 2) {
            active->client->mVsyncEnabled.store(true);
            active->epoch = FakeClock::current;
        }
    }
    require(++active->sleeps < 2000, "unbounded wait loop");
}
[[maybe_unused]] static void sleepUntil(FakeClock::time_point deadline) {
    const auto ns = deadline.time_since_epoch().count();
    require(ns >= FakeClock::current, "replayed an expired deadline");
    require(ns >= active->previousEnd, "callback work was followed by a catch-up burst");
    FakeClock::current = ns + active->oversleep;
    active->wake = FakeClock::current;
    require(++active->sleeps < 2000, "unbounded deadline loop");
    if (active->replaceOnWake) {
        active->client->mCallback = std::make_shared<Callback>(Callback{active->client, 1});
        active->expectedCallback = 1;
        active->replaceOnWake = false;
    }
    if (active->stopOnWake) active->client->mStopVsync.store(true);
    if (active->disableOnWake) {
        active->client->mVsyncEnabled.store(false);
        active->disableOnWake = false;
    }
}
static void warning(const char* format, ...) {
    if (std::string(format) == "vsync callback failed: %s") ++active->warnings;
}
#define ALOGW(...) warning(__VA_ARGS__)

// INSERT_ACTUAL_CLOCK
// INSERT_ACTUAL_LOOP

Status Callback::onVsync(int64_t display, int64_t timestamp, int32_t period) {
    require(display == ComposerClient::kDisplayId, "wrong display identity");
    require(identity == active->expectedCallback, "stale callback delivered after replacement");
    require(period == client->mVsyncPeriodNs, "changed advertised period");
    require(client->mVsyncEnabled.load() && !client->mStopVsync.load(), "disabled/stopped callback");
    require(client->mMutex.try_lock(), "callback invoked under the service mutex");
    client->mMutex.unlock();
    require(timestamp <= active->wake && active->wake - timestamp < period, "event timestamp is not the latest due tick");
    require((timestamp - active->epoch) % period == 0, "callback work or late wake changed the vsync phase");
    if (!active->ticks.empty()) require(timestamp > active->ticks.back(), "non-increasing event timestamps");
    if (active->constantCadence) {
        require(timestamp == active->epoch + int64_t(active->delivered + 1) * period,
                "callback duration accumulated into the period");
    }
    active->ticks.push_back(timestamp);
    FakeClock::current += active->callbackDelay;
    active->previousEnd = FakeClock::current;
    if (++active->delivered == active->limit) client->mStopVsync.store(true);
    return {!active->failCallback};
}

#ifndef CADENCE_ONLY
#define PROPERTY_VALUE_MAX 92
static std::string property;
static int property_get(const char* key, char* value, const char* fallback) {
    assert(std::string(key) == "vendor.royd.display.fps");
    assert(std::string(fallback).empty());
    std::strcpy(value, property.c_str());
    return property.size();
}
// INSERT_ACTUAL_PROPERTY
static void checkProperties() {
    for (int fps = 1; fps <= 1000; ++fps) {
        property = std::to_string(fps);
        assert(propertyInt("vendor.royd.display.fps", 30, 1000) == fps);
        assert(1000000000LL / fps > 0);
    }
    for (auto value : {"", "0", "-1", "bad", "30junk", "1001", "1000000001", "2147483647", "9223372036854775808"}) {
        property = value;
        assert(propertyInt("vendor.royd.display.fps", 30, 1000) == 30);
    }
    property = "1000000001";
    assert(propertyInt("vendor.royd.display.fps", 30) == 1000000001);
}
#endif

int main() {
    try {
        unsigned cases = 0;
        for (int fps : {1, 24, 30, 60, 90, 120, 240, 1000}) {
            const int32_t period = 1000000000LL / fps;
            for (int64_t epoch : {0LL, 1570000000000000LL}) {
                for (int64_t delay : {int64_t(period / 20), int64_t{0}, int64_t(period * 2 / 5), int64_t(period), int64_t(period) * 7 / 2}) {
                    for (int64_t late : {int64_t{0}, int64_t(period / 10), int64_t(period) * 23 / 10}) {
                      for (int64_t lock : {int64_t{0}, int64_t(period / 4), int64_t(period) * 13 / 10}) {
                        ComposerClient client;
                        client.mVsyncPeriodNs = period;
                        client.mCallback = std::make_shared<Callback>(Callback{&client});
                        Scenario scenario{};
                        scenario.client = &client; scenario.epoch = epoch;
                        scenario.callbackDelay = delay; scenario.oversleep = late;
                        scenario.lockDelay = lock;
                        scenario.constantCadence = delay + lock < period && late == 0;
                        FakeClock::current = epoch; active = &scenario;
                        client.vsyncLoop();
                        require(scenario.delivered == scenario.limit, "missing callback sequence");
                        ++cases;
                      }
                    }
                }
            }
        }
#ifndef CADENCE_ONLY
        for (int mode = 0; mode < 5; ++mode) {
            ComposerClient client;
            client.mVsyncPeriodNs = 33333333;
            client.mCallback = std::make_shared<Callback>(Callback{&client});
            Scenario scenario{}; scenario.client = &client; scenario.epoch = 1000000000;
            scenario.limit = 3; scenario.stopOnWake = mode == 0;
            scenario.disableOnWake = mode == 1; scenario.failCallback = mode == 2;
            scenario.replaceOnWake = mode == 4;
            if (mode == 3) client.mCallback.reset(), scenario.stopOnWake = true;
            FakeClock::current = scenario.epoch; active = &scenario;
            client.vsyncLoop();
            require(scenario.delivered == (scenario.stopOnWake ? 0U : 3U), "lifecycle delivery mismatch");
            require(scenario.warnings == (scenario.failCallback ? 3U : 0U), "callback failure diagnostic changed");
            if (mode == 1) require(scenario.polls == 2, "disabled wait was bypassed");
        }
        checkProperties();
#endif
        std::cout << "Actual composer vsync passed: " << cases
                  << " delayed-callback/wake cases plus lifecycle/property controls\n";
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
