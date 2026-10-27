#include <assert.h>
#include <arpa/inet.h>
#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <linux/ipv6.h>
#include <linux/tcp.h>
#include <linux/udp.h>
#include <linux/pkt_cls.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#undef __always_inline
#define __always_inline
#include "royd_quota.h"
static unsigned char frame[65536];
static struct RoydQuota quota;
static struct RoydQuotaDrops drops;
static int quota_budget, present, bad_read;
static void* bpf_map_lookup_elem_unsafe(void* map, const uint32_t* key) {
    assert(map == &quota_budget);
    return present && *key == 2 ? &quota : NULL;
}
static struct RoydQuotaDrops* bpf_quota_drops_lookup_elem(const uint32_t* key) {
    assert(!*key);return &drops;
}
static int bpf_skb_load_bytes(const struct __sk_buff* skb, unsigned off, void* dst, unsigned len) {
    if (bad_read || off > skb->len || len > skb->len - off || off + len > sizeof(frame)) return -1;
    memcpy(dst,frame+off,len);return 0;
}
#include "royd_iface_account.h"
#include "quota-packet-function.h"
int main(void) {
    struct ethhdr* eth = (void*)frame;
    struct iphdr* ip = (void*)(frame+ETH_HLEN);
    eth->h_proto = htons(ETH_P_IP);ip->version = 4;ip->ihl = 5;
    ip->tot_len = htons(9620);ip->protocol = IPPROTO_UDP;
    struct __sk_buff skb = {.len=ETH_HLEN+9620,.gso_segs=8,.ifindex=2};
    // The complete aggregate costs 9620 + 7*28 = 9816 IP bytes.
    present = 1;quota = (struct RoydQuota){9816,9816,1};
    assert(royd_quota_packet(&skb) == TC_ACT_UNSPEC && !quota.remaining);
    quota = (struct RoydQuota){9815,9815,2};
    assert(royd_quota_packet(&skb) == TC_ACT_SHOT && !quota.remaining);
    assert(!drops.invalid && !drops.contention);
    quota = (struct RoydQuota){20000,20000,3};bad_read = 1;
    assert(royd_quota_packet(&skb) == TC_ACT_SHOT && quota.remaining == 20000 && drops.invalid == 1);
    bad_read = 0;eth->h_proto = htons(ETH_P_ARP);
    assert(royd_quota_packet(&skb) == TC_ACT_UNSPEC && quota.remaining == 20000);
    eth->h_proto = htons(ETH_P_IP);skb.ifindex = 3;
    assert(royd_quota_packet(&skb) == TC_ACT_UNSPEC && quota.remaining == 20000);
    present = 0;skb.ifindex = 2;
    assert(royd_quota_packet(&skb) == TC_ACT_UNSPEC && quota.remaining == 20000);
    puts("Quota packet whole-GSO, malformed, L2 and unselected-interface contracts passed");
}
