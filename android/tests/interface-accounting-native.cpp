#include <cassert>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <linux/bpf.h>
#include <net/if.h>
#include <net/if_arp.h>
#include <string>
#include <sys/stat.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <unistd.h>

static const char* marker;
static int probe_errno, probes, calls, closes, creates, config_writes, stats_writes;
static int failure, bad_link, bad_layout;
static unsigned iface = 2, selected, errors;
static bool pins[2], stats_present;
static bool bad_ethernet;
static bool inject_error_at_activation;
static uint64_t stats_bytes;
void royd_test_close(int fd) { assert(fd >= 100); closes++; }
static char* fake_getenv(const char* name) {
    assert(!strcmp(name, "ROYD_CONTAINER")); return const_cast<char*>(marker);
}
static int fake_stat(const char* path, struct stat*) {
    assert(!strcmp(path, "/sys/fs/selinux/enforce")); probes++;
    errno = probe_errno; return probe_errno ? -1 : 0;
}
static unsigned fake_ifindex(const char* name) { assert(!strcmp(name, "eth0")); return iface; }
static int fake_socket(int domain, int type, int protocol) {
    assert(domain == AF_INET && type == (SOCK_DGRAM | SOCK_CLOEXEC) && protocol == 0);
    return 1000;
}
static int fake_ioctl(int fd, unsigned long op, struct ifreq* request) {
    assert(fd == 1000 && op == SIOCGIFHWADDR && !strcmp(request->ifr_name, "eth0"));
    request->ifr_hwaddr.sa_family = bad_ethernet ? ARPHRD_LOOPBACK : ARPHRD_ETHER;
    return 0;
}
static long fake_syscall(long nr, ...);
#define getenv(name) fake_getenv(name)
#define stat(path, buf) fake_stat(path, buf)
#define if_nametoindex(name) fake_ifindex(name)
#define syscall fake_syscall
#define socket(a, b, c) fake_socket(a, b, c)
#define ioctl(a, b, c) fake_ioctl(a, b, c)
#include "RoydInterfaceAccounting.h"
#undef getenv
#undef stat
#undef if_nametoindex
#undef syscall
#undef socket
#undef ioctl

static long fake_syscall(long nr, ...) {
    assert(nr == __NR_bpf); calls++;
    va_list ap; va_start(ap, nr);
    int cmd = va_arg(ap, int); auto* a = va_arg(ap, union bpf_attr*);
    assert(va_arg(ap, size_t) == sizeof(*a)); va_end(ap);
    errno = EIO;
    if (cmd == BPF_OBJ_GET) {
        std::string p(reinterpret_cast<char*>(a->pathname));
        assert(p.find(android::net::royd::kRoot) == 0);
        if (p.find("map_netd_royd_iface_accounting_map") != std::string::npos) {
            return failure == 1 ? -1 : 100;
        }
        if (p.find("map_netd_iface_stats_map") != std::string::npos) return failure == 2 ? -1 : 101;
        if (p.find("map_netd_royd_iface_error_map") != std::string::npos) return failure == 16 ? -1 : 102;
        int d = p.find("ingress") == std::string::npos;
        if (p.find("prog_netd_schedcls_royd_") != std::string::npos) return failure == 3 ? -1 : 200+d;
        assert(p.find("link_royd_iface_") != std::string::npos);
        if (failure == 4) { errno = EACCES; return -1; }
        if (!pins[d]) { errno = ENOENT; return -1; }
        return 300+d;
    }
    if (cmd == BPF_OBJ_GET_INFO_BY_FD) {
        if (failure == 5) return -1;
        if (failure == 14) { a->info.info_len = 0; return 0; }
        if (a->info.bpf_fd < 200) {
            auto* m = reinterpret_cast<bpf_map_info*>(a->info.info);
            m->type = a->info.bpf_fd == 101 ? BPF_MAP_TYPE_HASH : BPF_MAP_TYPE_ARRAY;
            m->key_size = bad_layout == 1 ? 8 : 4;
            m->value_size = a->info.bpf_fd == 100 ? 8 : (a->info.bpf_fd == 101 ? 32 : 4);
            if (bad_layout == 2) m->value_size++;
            m->max_entries = bad_layout == 3 ? 0 : 1;
            if (failure == 15) a->info.info_len = offsetof(bpf_map_info, max_entries) + sizeof(m->max_entries);
        } else if (a->info.bpf_fd < 300) {
            auto* p = reinterpret_cast<bpf_prog_info*>(a->info.info);
            p->type = BPF_PROG_TYPE_SCHED_CLS; p->id = a->info.bpf_fd;
            if (failure == 15) a->info.info_len = offsetof(bpf_prog_info, id) + sizeof(p->id);
        } else {
            unsigned d = a->info.bpf_fd - 300;
            auto* l = reinterpret_cast<bpf_link_info*>(a->info.info);
            l->type = bad_link == 1 ? BPF_LINK_TYPE_XDP : BPF_LINK_TYPE_TCX;
            l->id = 300+d; l->prog_id = bad_link == 2 ? 999 : 200+d;
            l->tcx.ifindex = bad_link == 3 ? 0 : iface;
            l->tcx.attach_type = bad_link == 4 ? 0 : (d ? BPF_TCX_EGRESS : BPF_TCX_INGRESS);
            if (failure == 15) a->info.info_len = offsetof(bpf_link_info, tcx) + sizeof(l->tcx);
        }
        return 0;
    }
    if (cmd == BPF_MAP_LOOKUP_ELEM) {
        if (failure == 6) return -1;
        if (a->map_fd == 102) { *reinterpret_cast<unsigned*>(a->value) = errors; return 0; }
        if (a->map_fd == 101) {
            assert(*reinterpret_cast<unsigned*>(a->key) == iface);
            auto* c = reinterpret_cast<android::net::royd::Counters*>(a->value);
            c->rxBytes = stats_bytes;
            if (!stats_present) { errno = ENOENT; return -1; }
            return 0;
        }
        assert(a->map_fd == 100 && *reinterpret_cast<unsigned*>(a->key) == 0);
        auto* s = reinterpret_cast<android::net::royd::AccountingState*>(a->value);
        s->ifindex = selected; s->errors = 0; return 0;
    }
    if (cmd == BPF_MAP_UPDATE_ELEM) {
        if (a->map_fd == 101) {
            stats_writes++;
            assert(a->flags == BPF_NOEXIST && *reinterpret_cast<unsigned*>(a->key) == iface);
            if (failure == 7) return -1;
            if (stats_present) { errno = EEXIST; return -1; }
            stats_present = true; stats_bytes = 0; return 0;
        }
        assert(a->map_fd == 100 && a->flags == BPF_EXIST);
        config_writes++;
        if (inject_error_at_activation) errors = 1;
        if (failure == 8) return -1;
        const auto* s = reinterpret_cast<android::net::royd::AccountingState*>(a->value);
        assert(s->errors == 0); selected = s->ifindex; return 0;
    }
    if (cmd == BPF_LINK_CREATE) {
        creates++;
        assert(a->link_create.flags == BPF_F_BEFORE);
        assert(a->link_create.target_ifindex == iface);
        unsigned d = a->link_create.attach_type == BPF_TCX_EGRESS;
        assert(a->link_create.attach_type == (d ? BPF_TCX_EGRESS : BPF_TCX_INGRESS));
        assert(a->link_create.prog_fd == 200+d);
        if (failure == 9 || (failure == 10 && d)) return -1;
        return 300+d;
    }
    if (cmd == BPF_OBJ_PIN) {
        if (failure == 11) return -1;
        unsigned d = a->bpf_fd - 300; assert(d < 2); pins[d] = true; return 0;
    }
    if (cmd == BPF_PROG_QUERY) {
        if (failure == 12) return -1;
        unsigned d = a->query.attach_type == BPF_TCX_EGRESS;
        assert(a->query.target_ifindex == iface && a->query.prog_cnt == 64);
        a->query.prog_cnt = 1;
        *reinterpret_cast<unsigned*>(a->query.prog_ids) = 200+d;
        *reinterpret_cast<unsigned*>(a->query.link_ids) = failure == 13 ? 999 : 300+d;
        return 0;
    }
    assert(false); return -1;  // No deletion, replacement, host mutation or alternate syscall.
}
static void reset() {
    marker = "1"; probe_errno = ENOENT; iface = 2; selected = errors = 0;
    probes = calls = closes = creates = config_writes = stats_writes = 0;
    failure = bad_link = bad_layout = 0;
    pins[0] = pins[1] = stats_present = false; stats_bytes = 0;
    bad_ethernet = false;
    inject_error_at_activation = false;
}
int main() {
    unsigned cases = 0;
    for (const char* env : {static_cast<const char*>(nullptr), "", "0", "01", "true", "1"}) {
        for (int err : {0, ENOENT, EACCES, EIO, ENOTDIR}) {
            reset(); marker = env; probe_errno = err;
            bool gated = env && !strcmp(env, "1") && err == ENOENT;
            assert(android::net::royd::preserveQdisc("eth0") == gated);
            assert(!android::net::royd::preserveQdisc("eth1"));
            assert(!android::net::royd::preserveQdisc("v4-eth0"));
            assert(android::net::royd::initialise());
            assert((creates == 2) == gated);
            if (!gated) assert(calls == 0);
            cases++;
        }
    }
    for (int err = 1; err <= 14; err++) {
        reset(); failure = err;
        assert(!android::net::royd::initialise()); cases++;
        if (err != 12 && err != 13) assert(selected == 0);
    }
    for (int mode = 1; mode <= 4; mode++) {
        reset(); pins[0] = pins[1] = true; bad_link = mode;
        assert(!android::net::royd::initialise()); assert(creates == 0 && selected == 0); cases++;
    }
    for (int mode = 1; mode <= 3; mode++) {
        reset(); bad_layout = mode; assert(!android::net::royd::initialise()); cases++;
    }
    for (unsigned index : {0U, 1U}) {
        reset(); iface = index; assert(!android::net::royd::initialise()); cases++;
    }
    reset(); selected = 42; assert(!android::net::royd::initialise()); cases++;
    reset(); errors = 1; assert(!android::net::royd::initialise()); cases++;
    reset(); bad_ethernet = true; assert(!android::net::royd::initialise() && calls == 0); cases++;
    reset(); failure = 15; assert(android::net::royd::initialise()); cases++;
    reset(); failure = 16; assert(!android::net::royd::initialise() && selected == 0); cases++;
    reset(); inject_error_at_activation = true;
    assert(!android::net::royd::initialise() && errors == 1); cases++;
    reset(); assert(android::net::royd::initialise()); assert(creates == 2 && config_writes == 1);
    stats_bytes = 123456; assert(android::net::royd::initialise());
    assert(creates == 2 && config_writes == 1 && stats_bytes == 123456 && closes > 0); cases++;
    errors = 1; unsigned index = 0, error = 0;
    assert(!android::net::royd::ready(index, error) && error == 1); cases++;
    puts("Interface accounting native gate/ownership contracts passed");
    printf("Native cases: %u\n", cases);
}
