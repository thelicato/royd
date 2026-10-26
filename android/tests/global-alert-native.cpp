#include <cassert>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <mutex>
#include <thread>
#include "RoydGlobalAlert.h"
using namespace android::net::royd;
using namespace std::chrono_literals;

struct Fixture {
    std::mutex lock;
    std::condition_variable changed;
    AlertSample sample{2, 17, 18, 19, 100, 200};
    int failure = 0, callbacks = 0;
    uint64_t notified = 0;
    bool hold = false, reading = false;
    int read(AlertSample& out) {
        std::unique_lock guard(lock);
        // Only the polling worker blocks. Registration stays independently live.
        if (hold && std::this_thread::get_id() != owner) {
            reading = true;
            changed.notify_all();
            changed.wait(guard, [&] { return !hold; });
        }
        out = sample;
        return failure;
    }
    bool notify(uint64_t generation) {
        std::lock_guard guard(lock);
        ++callbacks; notified = generation; changed.notify_all(); return true;
    }
    void waitCallbacks(int count) {
        std::unique_lock guard(lock);
        assert(changed.wait_for(guard, 2s, [&] { return callbacks >= count; }));
    }
    void advance(uint64_t rx, uint64_t tx) {
        std::lock_guard guard(lock); sample.rx += rx; sample.tx += tx;
    }
    std::thread::id owner = std::this_thread::get_id();
};
static void waitError(GlobalAlert& alert, int expected) {
    const auto deadline = std::chrono::steady_clock::now() + 2s;
    while (!alert.status().error && std::chrono::steady_clock::now() < deadline) {
        std::this_thread::yield();
    }
    assert(alert.status().error == expected && !alert.status().armed);
}
static int failStart(pthread_t*, const pthread_attr_t*, void* (*)(void*), void*) { return EAGAIN; }
int main() {
    {
        Fixture f;
        GlobalAlert alert([&](auto& s) { return f.read(s); }, [&](auto g) { return f.notify(g); }, 1ms);
        assert(alert.cancel() == -ENOENT);
        for (auto bytes : {int64_t(0), int64_t(-1), std::numeric_limits<int64_t>::min()}) {
            assert(alert.arm(bytes) == -ERANGE);
        }
        assert(alert.status().generation == 0);
        assert(alert.arm(100) == 0);
        f.advance(50, 49);
        std::this_thread::sleep_for(15ms);
        assert(alert.status().armed && alert.status().committed == 0);
        f.advance(0, 1); f.waitCallbacks(1);
        assert(!alert.status().armed && alert.status().committed == 1);
        f.advance(1000, 1000);
        std::this_thread::sleep_for(15ms);
        assert(alert.status().committed == 1);
        assert(alert.arm(20) == 0); // New baseline, not a pending old crossing.
        std::this_thread::sleep_for(15ms);
        assert(alert.status().armed && alert.status().committed == 1);
        f.advance(0, 20); f.waitCallbacks(2);
        assert(alert.arm(1) == 0);
        assert(alert.cancel() == 0);
        assert(alert.cancel() == -ENOENT);
        f.advance(1000, 1000);
        std::this_thread::sleep_for(15ms);
        assert(!alert.status().armed && alert.status().committed == 2);
    }
    // Cancellation/replacement during a pending read invalidates its generation.
    for (bool cancel : {false, true}) {
        Fixture f;
        GlobalAlert alert([&](auto& s) { return f.read(s); }, [&](auto g) { return f.notify(g); }, 1ms);
        assert(alert.arm(1) == 0);
        {
            std::unique_lock guard(f.lock);
            f.hold = true;
            assert(f.changed.wait_for(guard, 2s, [&] { return f.reading; }));
            f.sample.rx += 100;
        }
        if (cancel) assert(alert.cancel() == 0);
        else assert(alert.arm(1000) == 0);
        {
            std::lock_guard guard(f.lock); f.hold = false; f.changed.notify_all();
        }
        std::this_thread::sleep_for(15ms);
        assert(alert.status().committed == 0);
    }
    // Counter regression, disappearance/reuse and read failure are sticky faults.
    for (int mode = 0; mode != 7; ++mode) {
        Fixture f;
        GlobalAlert alert([&](auto& s) { return f.read(s); }, [&](auto g) { return f.notify(g); }, 1ms);
        assert(alert.arm(100) == 0);
        {
            std::lock_guard guard(f.lock);
            if (mode == 0) f.failure = -EIO;
            if (mode == 1) f.sample.rx--;
            if (mode == 2) f.sample.tx--;
            if (mode == 3) f.sample.map++;
            if (mode == 4) f.sample.ingress += 10;
            if (mode == 5) f.sample.ifindex++;
            if (mode == 6) f.sample.map = 0;
        }
        const int error = mode == 0 || mode == 6 ? EIO : ESTALE;
        waitError(alert, error);
        assert(alert.arm(10) == -error);
        assert(alert.status().committed == 0);
    }
    {
        Fixture f;
        GlobalAlert alert([&](auto& s) { return f.read(s); }, [&](auto g) { return f.notify(g); }, 1ms, failStart);
        assert(alert.arm(100) == -EAGAIN);
        assert(alert.status().generation == 0 && !alert.status().armed);
    }
    {
        Fixture f;
        GlobalAlert alert([&](auto& s) { return f.read(s); }, [&](auto g) { return f.notify(g); }, 1ms);
        assert(alert.arm(100) == 0);
        { std::lock_guard guard(f.lock); f.failure = -ENODATA; }
        assert(alert.arm(200) == -ENODATA);
        assert(alert.status().bytes == 100 && alert.status().generation == 1);
    }
    // RX+TX near UINT64_MAX must not wrap into an apparently unused window.
    {
        Fixture f;
        f.sample.rx = f.sample.tx = 0;
        GlobalAlert alert([&](auto& s) { return f.read(s); }, [&](auto g) { return f.notify(g); }, 1ms);
        assert(alert.arm(std::numeric_limits<int64_t>::max()) == 0);
        f.advance(std::numeric_limits<uint64_t>::max()-1, 100);
        f.waitCallbacks(1);
    }
    // Real callback re-entry must never wait for a backend lock it already owns.
    {
        Fixture f;
        GlobalAlert* self = nullptr;
        std::atomic<int> result{-1};
        GlobalAlert alert([&](auto& s) { return f.read(s); }, [&](uint64_t g) {
            result = self->arm(1000);
            return f.notify(g);
        }, 1ms);
        self = &alert;
        assert(alert.arm(1) == 0);
        f.advance(1, 0); f.waitCallbacks(1);
        assert(result == 0 && alert.status().generation == 2 && alert.status().armed);
    }
    {
        Fixture f;
        GlobalAlert alert([&](auto& s) { return f.read(s); }, [](uint64_t) { return false; }, 1ms);
        assert(alert.arm(1) == 0);
        f.advance(1, 0); waitError(alert, EIO);
        assert(alert.status().committed == 1);
    }
    puts("Global alert thresholds, generations, failures, overflow and callback re-entry passed");
}
