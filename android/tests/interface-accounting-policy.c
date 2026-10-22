#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <pthread.h>

#undef __always_inline
#define __always_inline
#define TC_ACT_UNSPEC (-1)
struct __sk_buff { uint32_t ifindex; };
struct RoydAccountingState { uint32_t ifindex; uint32_t errors; };
typedef struct { uint64_t rxPackets, rxBytes, txPackets, txBytes; } StatsValue;
static struct RoydAccountingState state;
static StatsValue stats;
static bool no_state, no_stats;
static int outcome = 1;
static struct RoydAccountingState* bpf_royd_iface_accounting_map_lookup_elem(uint32_t* key) {
    assert(*key == 0); return no_state ? NULL : &state;
}
static StatsValue* bpf_iface_stats_map_lookup_elem(uint32_t* key) {
    assert(*key == state.ifindex); return no_stats ? NULL : &stats;
}
static uint32_t* bpf_royd_iface_error_map_lookup_elem(uint32_t* key) {
    assert(*key == 0); return &state.errors;
}
static int royd_ip_counters(const struct __sk_buff* skb, uint64_t* bytes, uint64_t* packets) {
    assert(skb->ifindex == state.ifindex); *bytes = 128; *packets = 2; return outcome;
}
#include "royd_accounting_functions.h"
static void* flow(void* arg) {
    struct __sk_buff skb = {42};
    for (unsigned i = 0; i < 100000; i++) {
        assert(royd_account_iface(&skb, (uintptr_t)arg & 1) == TC_ACT_UNSPEC);
    }
    return NULL;
}
int main(void) {
    struct __sk_buff skb = {42};
    assert(!royd_owns_iface(42));
    assert(royd_account_iface(&skb, true) == TC_ACT_UNSPEC && stats.txBytes == 0);
    state.ifindex = 42; assert(royd_owns_iface(42) && !royd_owns_iface(1));
    no_state = true; assert(!royd_owns_iface(42));
    royd_account_iface(&skb, true); assert(stats.txBytes == 0); no_state = false;
    skb.ifindex = 43; royd_account_iface(&skb, false); assert(stats.rxBytes == 0);
    skb.ifindex = 42; outcome = 0; royd_account_iface(&skb, true);
    assert(stats.txBytes == 0 && state.errors == 0);
    outcome = -1; royd_account_iface(&skb, true); assert(state.errors == 1);
    state.errors = 1; royd_account_iface(&skb, true); assert(state.errors == 1);
    outcome = 1; no_stats = true; state.errors = 0;
    royd_account_iface(&skb, true); assert(state.errors == 1 && stats.txBytes == 0);
    no_stats = false; state.errors = 0;
    pthread_t threads[16];
    for (uintptr_t i = 0; i < 16; i++) assert(!pthread_create(&threads[i], NULL, flow, (void*)i));
    for (unsigned i = 0; i < 16; i++) assert(!pthread_join(threads[i], NULL));
    assert(stats.rxBytes == 800000ULL * 128 && stats.txBytes == stats.rxBytes);
    assert(stats.rxPackets == 1600000 && stats.txPackets == stats.rxPackets);
    assert(state.errors == 0);
    puts("Interface map selection/error/concurrency contracts passed: 1600000 packets");
}
