#include <cassert>
#include <cstdint>
#include <cstring>
#include <cstdio>
#include <cerrno>
#include <linux/bpf.h>
#include <string>
#include <time.h>
#include <mutex>
#include <limits>

namespace android::net::royd {
static bool gated = true, present, pinned[2];
static int fault, writes, creates, deleted, closed;
static unsigned key = 2;
static uint64_t usage;
struct Saved { uint64_t remaining, limit, generation; } saved;
static constexpr const char* kRoot = "/sys/fs/bpf/netd_shared/";
struct unique_fd {
    int value; explicit unique_fd(int fd):value(fd) {}
    ~unique_fd() { if (ok()) ++closed; }
    bool ok() const { return value >= 0; }
    int get() const { return value; }
    void reset(int fd) { if (ok()) ++closed;value = fd; }
};
static bool enabled() { return gated; }
static bool ready(uint32_t& index, uint32_t&) { index = 2;return fault != 1; }
static int object(const char* name) {
    if (fault == 2) { errno = EACCES;return -1; }
    if (!strcmp(name,"map_roydquota_quota_budget")) return 10;
    if (!strcmp(name,"map_roydquota_quota_drops")) return 11;
    if (!strcmp(name,"map_roydquota_quota_admitted")) return 12;
    int direction = strstr(name,"egress") != nullptr;
    if (strstr(name,"prog_roydquota")) return 20+direction;
    if (strstr(name,"link_royd_iface")) return 30+direction;
    assert(strstr(name,"link_royd_quota"));
    if (fault == 3) { errno = EACCES;return -1; }
    if (!pinned[direction]) { errno = ENOENT;return -1; }
    return 40+direction;
}
template<class T> static bool info(int fd, T& output, uint32_t) {
    if (fault == 4) return false;
    if (fd == 12) {
        auto* value = reinterpret_cast<bpf_map_info*>(&output);
        value->type = BPF_MAP_TYPE_ARRAY;value->key_size = 4;value->value_size = 8;
        value->id = fault == 19 ? 0 : 112;value->max_entries = 1;
    } else if (fd == 10) {
        auto* value = reinterpret_cast<bpf_map_info*>(&output);
        value->type = BPF_MAP_TYPE_HASH;value->key_size = 4;value->value_size = 24;
        value->max_entries = 1;value->map_flags = BPF_F_NO_PREALLOC;
        if (fault == 5) value->map_flags = 0;
        if (fault == 6) value->value_size = 8;
        if (fault == 7) value->max_entries = 2;
    } else {
        assert(fd >= 30);
        reinterpret_cast<bpf_link_info*>(&output)->id = fd;
    }
    return true;
}
static bool mapLayout(int fd, uint32_t type, uint32_t size) {
    assert(type == BPF_MAP_TYPE_ARRAY && ((fd == 11 && size == 16) || (fd == 12 && size == 8)));
    return fault != 8 && !(fd == 12 && fault == 18);
}
static bool validLink(int fd, int program, uint32_t index, uint32_t direction) {
    assert(index == 2 && fd == 40+(direction == BPF_TCX_EGRESS));
    assert(program == fd-20);return fault != 9;
}
static int bpfCall(enum bpf_cmd cmd, union bpf_attr& attr) {
    if (cmd == BPF_MAP_GET_NEXT_KEY) {
        assert(attr.map_fd == 10 && !attr.key);
        if (fault == 10) { errno = EACCES;return -1; }
        if (!present) { errno = ENOENT;return -1; }
        *reinterpret_cast<uint32_t*>(attr.next_key) = key;return 0;
    }
    if (cmd == BPF_LINK_CREATE) {
        ++creates;
        if (fault == 11) { errno = EOPNOTSUPP;return -1; }
        int direction = attr.link_create.attach_type == BPF_TCX_EGRESS;
        assert(attr.link_create.flags == (BPF_F_AFTER|BPF_F_LINK|BPF_F_ID));
        assert(attr.link_create.tcx.relative_id == unsigned(30+direction));
        assert(attr.link_create.prog_fd == unsigned(20+direction) && attr.link_create.target_ifindex == 2);
        return 40+direction;
    }
    if (cmd == BPF_OBJ_PIN) {
        if (fault == 12) return -1;
        assert(attr.bpf_fd >= 40 && attr.bpf_fd <= 41);
        pinned[attr.bpf_fd-40] = true;return 0;
    }
    if (cmd == BPF_PROG_QUERY) {
        if (fault == 13) return -1;
        int direction = attr.query.attach_type == BPF_TCX_EGRESS;
        const unsigned capacity = attr.query.prog_cnt;
        attr.query.prog_cnt = 2;
        // Linux returns the count without filling either array in this case.
        if (!capacity || !attr.query.prog_ids) return 0;
        auto* programs = reinterpret_cast<uint32_t*>(attr.query.prog_ids);
        programs[0] = 10+direction;programs[1] = 20+direction;
        auto* ids = reinterpret_cast<uint32_t*>(attr.query.link_ids);
        ids[0] = 30+direction;ids[1] = 40+direction;
        if (fault == 14) { ids[0] = 40+direction;ids[1] = 30+direction; }
        return 0;
    }
    assert(cmd == BPF_MAP_DELETE_ELEM && attr.map_fd == 10);
    if (fault == 15) { errno = EPERM;return -1; }
    if (!present) { errno = ENOENT;return -1; }
    ++deleted;present = false;return 0;
}
template<class T> static bool lookup(int fd, uint32_t index, T& output) {
    if (fault == 16) { errno = EIO;return false; }
    if (fd == 12) { assert(index == 0);memcpy(&output,&usage,sizeof(usage));return true; }
    if (fd == 11) { assert(index == 0);memset(&output,0,sizeof(output));return true; }
    assert(fd == 10 && index == 2);
    if (!present) { errno = ENOENT;return false; }
    memcpy(&output,&saved,sizeof(saved));return true;
}
template<class T> static int update(int fd, uint32_t index, const T& value, uint64_t flags) {
    assert(fd == 10 && index == 2 && flags == BPF_ANY);
    if (fault == 17) { errno = ENOMEM;return -1; }
    ++writes;memcpy(&saved,&value,sizeof(saved));present = true;return 0;
}
}
// The real accounting header has its own independent gate/syscall contracts.
#include "RoydInterfaceQuota.h"
using namespace android::net::royd;
static void reset() {
    gated = true;present = false;pinned[0] = pinned[1] = false;
    fault = writes = creates = deleted = closed = 0;key = 2;saved = {};usage = 0;
}
int main() {
    reset();gated = false;assert(initialiseQuota() && creates == 0 && writes == 0);
    for (int failure = 1; failure <= 14; ++failure) {
        reset();fault = failure;assert(!initialiseQuota() && writes == 0);
    }
    reset();fault = 18;assert(!initialiseQuota() && writes == 0);
    reset();assert(initialiseQuota() && creates == 2 && closed > 0);
    assert(setQuota(0) == -ERANGE && setQuota(-2) == -ERANGE && !writes);
    assert(setQuota(1000) == 0 && writes == 1 && saved.remaining == 1000);
    auto old = saved; saved.remaining = 200;
    assert(initialiseQuota() && creates == 2 && saved.remaining == 200 && writes == 1);
    QuotaValue value = {};QuotaDrops drops = {};bool active = false;
    assert(readQuota(value,drops,active) == 0 && active && value.remaining == 200);
    assert(setQuota(500) == 0 && saved.remaining == 500 && saved.generation > old.generation);
    old = saved;fault = 17;
    assert(setQuota(250) == -ENOMEM && !memcmp(&old,&saved,sizeof(old)));
    fault = 15;assert(removeQuota() == -EPERM && present);
    fault = 16;assert(readQuota(value,drops,active) == -EIO);
    fault = 0;saved.generation = UINT64_MAX;assert(setQuota(1) == -EOVERFLOW);
    saved.generation = 0;assert(setQuota(1) == -EIO);
    saved = {100,100,1};key = 42;assert(!initialiseQuota() && setQuota(1) == -EIO);
    key = 2;assert(removeQuota() == 0 && !present && deleted == 1);
    assert(removeQuota() == -ENODEV);
    assert(readQuota(value,drops,active) == 0 && !active);
    puts("Quota native ownership, ordering, restart preservation and API failure contracts passed");
}
