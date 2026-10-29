#include <cassert>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <mutex>
#include <thread>
#include "RoydInterfaceAlert.h"
using namespace android::net::royd;
using namespace std::chrono_literals;

struct Fixture {
    std::mutex lock;
    std::condition_variable changed;
    InterfaceAlertSample sample{{2, 17, 18, 19, 20, 21}, 100};
    int failure = 0, removal = 0, callbacks = 0;
    bool quota = true, hold = false, reading = false;
    int read(InterfaceAlertSample& out) {
        std::unique_lock guard(lock);
        if (hold && std::this_thread::get_id() != owner) {
            reading = true; changed.notify_all();
            changed.wait(guard, [&] { return !hold; });
        }
        if (!quota) return -ENOENT;
        out = sample;
        return failure;
    }
    int remove() {
        std::lock_guard guard(lock);
        if (removal) return removal;
        if (!quota) return -ENODEV;
        quota = false;
        return 0;
    }
    bool notify(uint64_t) {
        std::lock_guard guard(lock); ++callbacks; changed.notify_all(); return true;
    }
    void waitCallbacks(int count) {
        std::unique_lock guard(lock);
        assert(changed.wait_for(guard, 2s, [&] { return callbacks >= count; }));
    }
    void advance(uint64_t bytes) {
        std::lock_guard guard(lock); sample.admitted += bytes;
    }
    std::thread::id owner = std::this_thread::get_id();
};
static void waitError(InterfaceAlert& alert, int expected) {
    const auto deadline = std::chrono::steady_clock::now() + 2s;
    while (!alert.status().error && std::chrono::steady_clock::now() < deadline) std::this_thread::yield();
    assert(alert.status().error == expected && !alert.status().armed);
}
static int failStart(pthread_t*, const pthread_attr_t*, void* (*)(void*), void*) { return EAGAIN; }
int main() {
    {
        Fixture f;
        InterfaceAlert a([&](auto& s) { return f.read(s); }, [&] { return f.remove(); },
                         [&](auto g) { return f.notify(g); }, 1ms);
        assert(a.cancel() == -ENOENT);
        for (auto n : {int64_t(0), int64_t(-1), INT64_MIN}) assert(a.arm(n) == -ERANGE);
        f.quota = false; assert(a.arm(1) == -ENOENT && !a.status().generation); f.quota = true;
        assert(a.arm(100) == 0);
        f.advance(99); std::this_thread::sleep_for(15ms);
        assert(a.status().armed && !a.status().committed);
        f.advance(1); f.waitCallbacks(1);
        f.advance(1000); std::this_thread::sleep_for(15ms);
        assert(a.status().committed == 1 && !a.status().armed);
        // Replacement uses the requested threshold and a fresh usage baseline.
        assert(a.arm(200) == 0 && a.status().bytes == 200);
        f.advance(100); std::this_thread::sleep_for(15ms); assert(a.status().committed == 1);
        assert(a.arm(10) == 0 && a.status().bytes == 10);
        f.advance(9); std::this_thread::sleep_for(15ms); assert(a.status().committed == 1);
        f.advance(1); f.waitCallbacks(2);
        assert(a.arm(1) == 0 && a.cancel() == 0 && a.cancel() == -ENOENT);
        f.advance(500); std::this_thread::sleep_for(15ms); assert(a.status().committed == 2);
        assert(a.arm(100) == 0);
        f.removal = -EPERM;
        auto before = a.status(); assert(a.removeQuota() == -EPERM);
        assert(a.status().generation == before.generation && a.status().armed && f.quota);
        f.removal = 0;assert(a.removeQuota() == 0 && !f.quota && !a.status().armed && !a.status().bytes);
        assert(a.cancel() == -ENOENT && a.arm(1) == -ENOENT && a.removeQuota() == -ENODEV);
        // Same private usage source survives a new quota, without old consumption.
        f.quota = true; assert(a.arm(10) == 0);f.advance(10); f.waitCallbacks(3);
    }
    // Every source identity member, regression and invalid sample is checked.
    for (int mode = 0; mode < 10; ++mode) {
        Fixture f;
        InterfaceAlert a([&](auto& s) { return f.read(s); }, [&] { return f.remove(); },
                         [&](auto g) { return f.notify(g); }, 1ms);
        assert(a.arm(100) == 0);
        {
            std::lock_guard guard(f.lock);
            if (mode < 6) f.sample.identity[mode] += 10;
            if (mode == 6) --f.sample.admitted;
            if (mode == 7) f.failure = -EIO;
            if (mode == 8) f.sample.identity[0] = 1;
            if (mode == 9) f.quota = false;
        }
        int error = mode < 7 ? ESTALE : mode == 9 ? ENOENT : EIO;
        waitError(a, error); assert(a.arm(10) == -error && !a.status().committed);
        assert(a.cancel() == 0 && a.arm(10) == -error); // Faults stay visible.
    }
    {
        Fixture f;
        InterfaceAlert a([&](auto& s) { return f.read(s); }, [&] { return f.remove(); },
                         [&](auto g) { return f.notify(g); }, 1ms, failStart);
        assert(a.arm(100) == -EAGAIN && !a.status().generation && !a.status().armed);
    }
    {
        Fixture f;
        InterfaceAlert a([&](auto& s) { return f.read(s); }, [&] { return f.remove(); },
                         [&](auto g) { return f.notify(g); }, 1ms);
        assert(a.arm(100) == 0);
        { std::lock_guard guard(f.lock); f.failure = -EACCES; }
        assert(a.arm(200) == -EACCES && a.status().bytes == 100);
    }
    // A read and quota removal are serialised. A committed notification may
    // finish, while the successful removal cancels all uncommitted work.
    {
        Fixture f;
        InterfaceAlert a([&](auto& s) { return f.read(s); }, [&] { return f.remove(); },
                         [&](auto g) { return f.notify(g); }, 1ms);
        assert(a.arm(100) == 0);
        {
            std::unique_lock guard(f.lock); f.hold = true;
            assert(f.changed.wait_for(guard, 2s, [&] { return f.reading; }));
        }
        std::atomic<bool> finished{false};
        std::thread remove([&] { assert(a.removeQuota() == 0);finished = true; });
        std::this_thread::sleep_for(10ms); assert(!finished);
        { std::lock_guard guard(f.lock); f.hold = false; f.changed.notify_all(); }
        remove.join(); assert(finished && !a.status().armed && !a.status().error);
        std::this_thread::sleep_for(15ms);assert(a.status().committed == 0);
    }
    // Notification callbacks can re-enter registration without any held lock.
    {
        Fixture f;
        InterfaceAlert* self = nullptr;std::atomic<int> rearmed{-1};
        InterfaceAlert a([&](auto& s) { return f.read(s); }, [&] { return f.remove(); },
                         [&](auto g) { rearmed = self->arm(1000);return f.notify(g); }, 1ms);
        self = &a;assert(a.arm(1) == 0); f.advance(1);f.waitCallbacks(1);
        assert(rearmed == 0 && a.status().generation == 2 && a.status().armed);
    }
    {
        Fixture f;
        InterfaceAlert a([&](auto& s) { return f.read(s); }, [&] { return f.remove(); },
                         [](auto) { return false; }, 1ms);
        assert(a.arm(1) == 0);f.advance(1);waitError(a, EIO); assert(a.status().committed == 1);
    }
    // A failed already-committed delivery cannot fault a cancelled/replaced window.
    for (bool rearm : {false, true}) {
        Fixture f;bool entered = false, release = false;
        InterfaceAlert a([&](auto& s) { return f.read(s); }, [&] { return f.remove(); },
                         [&](auto) {
                             std::unique_lock guard(f.lock);entered = true;f.changed.notify_all();
                             f.changed.wait(guard, [&] { return release; });
                             return false;
                         }, 1ms);
        assert(a.arm(1) == 0);f.advance(1);
        {
            std::unique_lock guard(f.lock);
            assert(f.changed.wait_for(guard, 2s, [&] { return entered; }));
        }
        assert(a.cancel() == 0);
        if (rearm) assert(a.arm(1000) == 0);
        { std::lock_guard guard(f.lock);release = true;f.changed.notify_all(); }
        std::this_thread::sleep_for(15ms);
        assert(!a.status().error && a.status().armed == rearm && a.status().committed == 1);
    }
    // No RX+TX sum or signed conversion can wrap the unsigned usage delta.
    {
        Fixture f;f.sample.admitted = 0;
        InterfaceAlert a([&](auto& s) { return f.read(s); }, [&] { return f.remove(); },
                         [&](auto g) { return f.notify(g); }, 1ms);
        assert(a.arm(INT64_MAX) == 0);f.advance(UINT64_MAX - 1);f.waitCallbacks(1);
    }
    puts("Interface alert thresholds, source identity, removal, faults and re-entry passed");
}
