// Optional query regression. Only fresh, unpinned links in this process's new netns.
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <cassert>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <linux/bpf.h>
#include <net/if.h>
#include <sched.h>
#include <stddef.h>
#include <string>
#include <sys/syscall.h>
#include <unistd.h>

static int anchorProgram, quotaProgram, anchor[2] = {-1,-1}, quota[2] = {-1,-1};
static uint32_t testIfindex;
static bool checking;
static int raw(enum bpf_cmd command, union bpf_attr& attr) {
    return syscall(__NR_bpf,command,&attr,sizeof(attr));
}
static int bpfCall(enum bpf_cmd command, union bpf_attr& attr) {
    assert(checking && (command == BPF_OBJ_GET_INFO_BY_FD || command == BPF_PROG_QUERY));
    return raw(command,attr);
}
struct unique_fd {
    int fd;explicit unique_fd(int value):fd(value) {}
    ~unique_fd() { if (fd >= 0) close(fd); }
    bool ok() const { return fd >= 0; }
    int get() const { return fd; }
    void reset(int value) { if (fd >= 0) close(fd);fd = value; }
};
static const char* kRoot = "/unused-test-resolver/";
static int object(const char* name) {
    const unsigned direction = strstr(name,"egress") != nullptr;
    if (strstr(name,"prog_roydquota")) return dup(quotaProgram);
    if (strstr(name,"link_royd_iface")) return dup(anchor[direction]);
    assert(strstr(name,"link_royd_quota"));return dup(quota[direction]);
}
#include "quota-link-functions.h"

static std::string netns() {
    char buffer[128] = {};
    ssize_t n = readlink("/proc/self/ns/net",buffer,sizeof(buffer)-1);
    assert(n > 0);return std::string(buffer,n);
}
static int program() {
    struct bpf_insn code[2] = {};
    code[0].code = BPF_ALU64|BPF_MOV|BPF_K;code[0].dst_reg = BPF_REG_0;code[0].imm = -1;
    code[1].code = BPF_JMP|BPF_EXIT;
    const char license[] = "Apache 2.0";
    union bpf_attr attr = {};
    attr.prog_type = BPF_PROG_TYPE_SCHED_CLS;attr.insn_cnt = 2;
    attr.insns = reinterpret_cast<uintptr_t>(code);attr.license = reinterpret_cast<uintptr_t>(license);
    int fd = raw(BPF_PROG_LOAD,attr);assert(fd >= 0);return fd;
}
static uint32_t id(int fd) {
    struct bpf_link_info info = {};
    union bpf_attr attr = {};attr.info.bpf_fd = fd;attr.info.info_len = sizeof(info);
    attr.info.info = reinterpret_cast<uintptr_t>(&info);
    assert(raw(BPF_OBJ_GET_INFO_BY_FD,attr) == 0 && info.id);return info.id;
}
static int attach(int prog, unsigned direction, int previous = -1) {
    union bpf_attr attr = {};
    attr.link_create.prog_fd = prog;attr.link_create.target_ifindex = testIfindex;
    attr.link_create.attach_type = direction ? BPF_TCX_EGRESS : BPF_TCX_INGRESS;
    attr.link_create.flags = previous < 0 ? BPF_F_BEFORE : BPF_F_AFTER|BPF_F_LINK|BPF_F_ID;
    if (previous >= 0) attr.link_create.tcx.relative_id = id(previous);
    int fd = raw(BPF_LINK_CREATE,attr);assert(fd >= 0);return fd;
}
static void empty(unsigned direction) {
    union bpf_attr attr = {};attr.query.target_ifindex = testIfindex;
    attr.query.attach_type = direction ? BPF_TCX_EGRESS : BPF_TCX_INGRESS;
    assert(raw(BPF_PROG_QUERY,attr) == 0 && !attr.query.prog_cnt);
}
int main() {
    std::string original = netns();
    assert(unshare(CLONE_NEWNET) == 0);
    std::string own = netns();assert(own != original);
    testIfindex = if_nametoindex("lo");assert(testIfindex == 1);
    anchorProgram = program();quotaProgram = program();
    for (unsigned direction = 0; direction < 2; ++direction) {
        empty(direction);
        anchor[direction] = attach(anchorProgram,direction);
        quota[direction] = attach(quotaProgram,direction,anchor[direction]);
        uint32_t linkIds[64] = {};
        union bpf_attr attr = {};attr.query.target_ifindex = testIfindex;
        attr.query.attach_type = direction ? BPF_TCX_EGRESS : BPF_TCX_INGRESS;
        attr.query.prog_cnt = 64;attr.query.link_ids = reinterpret_cast<uintptr_t>(linkIds);
        assert(raw(BPF_PROG_QUERY,attr) == 0 && attr.query.prog_cnt == 2);
        printf("direction=%u count_only=%u link_ids_only=%u,%u\n",direction,
               attr.query.prog_cnt,linkIds[0],linkIds[1]);
        checking = true;assert(quotaLink(testIfindex,direction == 0,false));checking = false;
        close(quota[direction]);close(anchor[direction]);empty(direction);
        quota[direction] = attach(quotaProgram,direction);
        anchor[direction] = attach(anchorProgram,direction,quota[direction]);
        checking = true;assert(!quotaLink(testIfindex,direction == 0,false));checking = false;
        close(quota[direction]);close(anchor[direction]);empty(direction);
    }
    close(anchorProgram);close(quotaProgram);
    printf("Production quotaLink live ordered/reversed checks passed in %s; original=%s\n",
           own.c_str(),original.c_str());
}
