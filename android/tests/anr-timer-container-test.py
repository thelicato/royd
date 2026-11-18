"""Exercise the patched timer and notification path with all freezer operations mocked."""
from pathlib import Path
import os
import resource
import subprocess
import sys

root, temporary = map(Path, sys.argv[1:])
resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
relative = Path('frameworks/base/services/core/jni/com_android_server_utils_AnrTimer.cpp')
source = temporary / relative
source.parent.mkdir(parents=True)
stock = (root / 'android/tests/fixtures/android15/AnrTimer.cpp').read_text()
source.write_text(stock)
subprocess.run(['patch', '--fuzz=0', '-s', '-p1', '-d', str(temporary)],
               input=(root / 'android/patches/android-15.0.0_r36/0092-services-avoid-anr-timer-self-freeze.patch').read_text(),
               text=True, check=True)
patched = source.read_text()


def block(text, signature):
    start = text.index(signature)
    opening = text.index('{', start)
    depth = 1
    for end in range(opening + 1, len(text)):
        depth += (text[end] == '{') - (text[end] == '}')
        if not depth:
            return text[start:end + 1]
    raise AssertionError(signature)


methods = ['bool expire()', 'void accept()', 'void discard()', 'void release()',
           'void maybeFreezeProcess()', 'void maybeUnfreezeProcess()']
service_signature = 'void AnrTimerService::expire(timer_id_t timerId)'
for signature in [*methods, service_signature]:
    if signature != 'void maybeFreezeProcess()':
        assert block(patched, signature) == block(stock, signature), signature
if os.environ.get('ROYD_ANDROID15_ANR_TIMER_SOURCE'):
    applied = (Path(os.environ['ROYD_ANDROID15_ANR_TIMER_SOURCE']) / relative).read_text()
    for signature in [*methods, service_signature]:
        assert block(applied, signature) == block(patched, signature), signature

harness = r'''
#include <atomic>
#include <cassert>
#include <cerrno>
#include <climits>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <initializer_list>
#include <string>
#include <unistd.h>
#include <vector>
using nsecs_t = long long;
static const char* marker;
static int fault, probes, freezes, thaws, warnings, deliveries;
static bool live = true, profileResult = true;
static nsecs_t delay;
static std::vector<std::string> events;
static pid_t mockGetpid() { return 42; }
static uid_t mockGetuid() { return 1000; }
static const char* mockGetenv(const char* name) {
    assert(!strcmp(name, "ROYD_CONTAINER")); return marker;
}
static int mockAccess(const char* path, int mode) {
    assert(!strcmp(path, "/sys/fs/selinux/enforce") && mode == F_OK);
    probes++; errno = fault; return fault ? -1 : 0;
}
static void warning(const char* text) {
    assert(!strcmp(text, "ROYD: skipping ANR-timer self-freeze")); warnings++;
}
#define getpid mockGetpid
#define getuid mockGetuid
#define getenv mockGetenv
#define access mockAccess
#define ALOGW(text) warning(text)
#define ALOGI(...) ((void)0)
#define ALOGE(...) ((void)0)
#define ALOGW_IF(...) ((void)0)
static bool SetProcessProfiles(int uid, int pid, std::initializer_list<const char*> profiles) {
    assert((uid == -1 || uid == 1000 || uid == 10001) && (pid == 42 || pid == 51) && profiles.size() == 1);
    std::string name = *profiles.begin();
    if (name == "Frozen") { freezes++; events.push_back("freeze"); }
    else { assert(name == "Unfrozen"); thaws++; events.push_back("thaw"); }
    return profileResult;
}
static void traceBegin(const char*, unsigned) {}
static void traceEnd(unsigned) {}
static nsecs_t now() { return 100; }
struct ProcessStats { nsecs_t cpu_delay = 0; void fill(int) { cpu_delay = delay; } };
struct AnrTimerTracer { enum { None, Trace, Expire }; };
struct AutoMutex { explicit AutoMutex(int&) {} };
class AnrTimerService {
public:
    using timer_id_t = int;
    enum Status { Invalid, Running, Expired, Canceled };
    struct Timer {
        int id = 7, pid = 42, uid = 1000;
        bool freeze = true, frozen = false, extend = false, extended = false, splitting = false;
        int split = 0, action = AnrTimerTracer::None;
        Status status = Running;
        nsecs_t timeout = 20, started = 10, scheduled = 30;
        ProcessStats initial;
        bool alive() const { return live; }
        std::string toString() const { return "timer"; }
        std::string getName() const { return "target"; }
        void event(const char* name) { events.push_back(name); }
        METHODS
    } timer;
    struct { int expired = 0, extended = 0; } counters_;
    int lock_ = 0;
    void *notifierCookie_ = nullptr, *notifierObject_ = nullptr;
    static bool notify(int id, int pid, int uid, nsecs_t elapsed, void*, void*) {
        assert(id == 7 && (pid == 42 || pid == 51) && (uid == -1 || uid == 1000 || uid == 10001) && elapsed == 90);
        deliveries++; events.push_back("notify"); return true;
    }
    decltype(&notify) notifier_ = notify;
    Timer removeLocked(int id) { assert(id == timer.id); return timer; }
    void insertLocked(const Timer& t) { timer = t; }
    void discard(int id) { assert(id == timer.id); timer.discard(); }
    void expire(timer_id_t timerId);
};
SERVICE_EXPIRE
static void reset() {
    probes = freezes = thaws = deliveries = 0;
    live = profileResult = true; delay = 0; events.clear();
}
int main() {
    int cases = 0;
    for (const char* value : {static_cast<const char*>(nullptr), "", "0", "01", "1"}) {
        for (int error : {0, ENOENT, EACCES, EIO, ENOTDIR}) {
            for (int pid : {42, 51}) {
              for (int uid : {-1, 1000, 10001}) {
                for (bool discard : {false, true}) {
                    reset(); marker = value; fault = error;
                    AnrTimerService s; s.timer.pid = pid; s.timer.uid = uid;
                    bool self = pid == 42 && uid == 1000;
                    bool gated = value && !strcmp(value, "1") && error == ENOENT && self;
                    s.expire(7);
                    assert(s.timer.status == AnrTimerService::Expired && s.counters_.expired == 1);
                    assert(s.counters_.extended == 0 && deliveries == 1);
                    assert(s.timer.frozen == !gated && freezes == int(!gated));
                    assert(events.back() == "notify");
                    assert(probes == int(self && value && !strcmp(value, "1")));
                    s.timer.accept();
                    if (discard) s.timer.discard(); else s.timer.release();
                    assert(!s.timer.frozen && thaws == int(!gated));
                    cases++;
                }
              }
            }
        }
    }
    // The on-demand warning is bounded across timer instances and releases.
    assert(warnings == 1);
    for (int i = 0; i < 32; i++) {
        reset(); marker = "1"; fault = ENOENT;
        AnrTimerService s; s.expire(7); s.timer.release();
        assert(deliveries == 1 && freezes == 0 && thaws == 0 && warnings == 1);
    }
    for (bool enabled : {false, true}) {
        reset(); marker = "1"; fault = ENOENT; live = enabled;
        AnrTimerService s; s.timer.freeze = !enabled; s.expire(7);
        assert(deliveries == 1 && probes == 0 && freezes == 0);
    }
    // Other processes keep failed-freeze and failed-thaw behaviour.
    reset(); marker = "1"; fault = ENOENT; profileResult = false;
    AnrTimerService failed; failed.timer.pid = 51; failed.expire(7); failed.timer.release();
    assert(freezes == 1 && thaws == 0 && !failed.timer.frozen && deliveries == 1);
    reset(); AnrTimerService retry; retry.timer.pid = 51; retry.expire(7);
    profileResult = false; retry.timer.release(); assert(retry.timer.frozen && thaws == 1);
    profileResult = true; retry.timer.release(); assert(!retry.timer.frozen && thaws == 2);
    // The unchanged scheduler extension still precedes expiry and notification.
    for (nsecs_t current : {-2, 5, 100}) {
        reset(); marker = "1"; fault = ENOENT; delay = current;
        AnrTimerService s; s.timer.extend = true; s.expire(7);
        if (current > 0) {
            assert(deliveries == 0 && s.counters_.extended == 1 && freezes == 0 && probes == 0);
            assert(s.timer.scheduled == 30 + (current > 20 ? 20 : current));
            s.expire(7);
        }
        assert(deliveries == 1 && s.timer.extended && freezes == 0);
    }
    for (int action : {AnrTimerTracer::None, AnrTimerTracer::Trace, AnrTimerTracer::Expire}) {
        reset(); marker = "1"; fault = ENOENT;
        AnrTimerService s; s.timer.split = 50; s.timer.action = action; s.expire(7);
        if (action != AnrTimerTracer::Expire) {
            assert(deliveries == 0 && freezes == 0 && probes == 0); s.expire(7);
        }
        assert(deliveries == 1 && freezes == 0 && s.timer.splitting);
    }
    printf("ANR timer contract passed: %d gate/release cases, expiry notification, extensions, split expiry, failures and bounded diagnostics\n", cases);
}
'''
harness = harness.replace('METHODS', '\n'.join(block(patched, signature) for signature in methods))
harness = harness.replace('SERVICE_EXPIRE', block(patched, service_signature))
test = temporary / 'anr-timer-contract.cpp'
test.write_text(harness)
binary = temporary / 'anr-timer-contract'
compiler = os.environ.get('CXX', 'c++')
subprocess.run([compiler, '-std=c++17', '-Wall', '-Wextra', '-Werror', str(test), '-o', str(binary)], check=True)
subprocess.run([str(binary)], check=True)
# A stock self-freeze and an overbroad guard must each fail the same behavioural test.
for name, mutated in [
    ('stock-self-freeze', harness.replace(block(patched, 'void maybeFreezeProcess()'),
                                         block(stock, 'void maybeFreezeProcess()'))),
    ('non-enoent', harness.replace('errno == ENOENT', 'errno != 0')),
    ('all-targets', harness.replace('if (pid == getpid() && uid >= 0 && static_cast<uid_t>(uid) == getuid())', 'if (true)')),
]:
    assert mutated != harness, name
    mutant = temporary / (name + '.cpp')
    mutant.write_text(mutated)
    output = temporary / name
    subprocess.run([compiler, '-std=c++17', str(mutant), '-o', str(output)], check=True)
    result = subprocess.run([str(output)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    assert result.returncode != 0, name
print('Mutation controls passed: stock self-freeze, non-ENOENT gating and other-target suppression rejected')
