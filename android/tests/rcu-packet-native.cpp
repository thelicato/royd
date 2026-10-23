#include <atomic>
#include <cassert>
#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <cstdio>
#include <linux/pfkeyv2.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>
#include <thread>
#include <vector>

static const char* marker;
static int selinuxError, keyError, packetError, closeError;
static std::atomic_int keyCalls, packetCalls, closeCalls, statCalls, logs;
static const char* testGetenv(const char* name) { assert(!strcmp(name, "ROYD_CONTAINER")); return marker; }
static int testStat(const char* path, struct stat*) {
    assert(!strcmp(path, "/sys/fs/selinux/enforce")); statCalls++;
    errno = selinuxError; return selinuxError ? -1 : 0;
}
static int testSocket(int family, int type, int protocol) {
    int error;
    if (family == AF_KEY) {
        assert(type == (SOCK_RAW | SOCK_CLOEXEC) && protocol == PF_KEY_V2);
        keyCalls++; error = keyError;
    } else {
        assert(family == AF_PACKET && type == (SOCK_DGRAM | SOCK_CLOEXEC) && protocol == 0);
        packetCalls++; error = packetError;
    }
    errno = error;
    return error ? -1 : 100;
}
static int testClose(int fd) { assert(fd == 100); closeCalls++; errno = closeError; return closeError ? -1 : 0; }
static void testLog(const char* value) {
    assert(!strcmp(value, "ROYD: using packet-socket RCU grace periods for network statistics")); logs++;
}
#define getenv testGetenv
#define stat(...) testStat(__VA_ARGS__)
#define socket testSocket
#define close testClose
#include "RoydNetworkStatsRcu.h"
#undef getenv
#undef stat
#undef socket
#undef close

int main() {
    int cases = 0;
    const char* values[] = {nullptr, "", "0", "true", "1"};
    for (const char* value : values)
    for (int probe : {0, ENOENT, EACCES, EIO, ENOTDIR})
    for (int key : {0, EAFNOSUPPORT, EACCES, EPERM, EMFILE})
    for (int packet : {0, EAFNOSUPPORT, EPERM})
    for (int closing : {0, EIO}) {
        marker=value; selinuxError=probe; keyError=key; packetError=packet; closeError=closing;
        keyCalls=packetCalls=closeCalls=statCalls=logs=0;
        royd::packetRcuReported=false;
        const bool gate=value && !strcmp(value, "1") && probe==ENOENT;
        const bool fallback=key==EAFNOSUPPORT && gate;
        int expected=key ? (fallback ? (packet ? -packet : -closing) : -key) : -closing;
        const char* operation=nullptr;
        for (int call=0; call<2; call++) assert(royd::synchronizeNetworkStatsRcu(operation)==expected);
        assert(keyCalls==2 && packetCalls==(fallback ? 2 : 0));
        assert(closeCalls==((key==0 || (fallback && packet==0)) ? 2 : 0));
        assert(statCalls==((key==EAFNOSUPPORT && value && !strcmp(value,"1")) ? 2 : 0));
        assert(logs==((fallback && !packet && !closing) ? 1 : 0));
        const char* expectedOperation = fallback ? (packet ? "nativeSynchronizeKernelRCU:packet_socket" : "nativeSynchronizeKernelRCU:packet_close") : (key ? "nativeSynchronizeKernelRCU:socket" : "nativeSynchronizeKernelRCU:close");
        assert(!strcmp(operation, expectedOperation));
        cases++;
    }
    marker="1"; selinuxError=ENOENT; keyError=EAFNOSUPPORT; packetError=closeError=0;
    keyCalls=packetCalls=closeCalls=statCalls=logs=0; royd::packetRcuReported=false;
    std::vector<std::thread> threads;
    for (int i=0; i<64; i++) threads.emplace_back([] {const char* operation; assert(royd::synchronizeNetworkStatsRcu(operation)==0);});
    for (auto& thread : threads) thread.join();
    assert(logs==1 && keyCalls==64 && packetCalls==64 && closeCalls==64);
    printf("Actual packet RCU gate/error/descriptor contracts passed: %d cases and 64 concurrent callers\n", cases);
}
