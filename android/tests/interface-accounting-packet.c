#include <assert.h>
#include <arpa/inet.h>
#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <linux/ipv6.h>
#include <linux/tcp.h>
#include <linux/udp.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#undef __always_inline
#define __always_inline
static unsigned char frame[131072];
static int fail_read;
static int bpf_skb_load_bytes(const struct __sk_buff* skb, unsigned off, void* dst, unsigned len) {
    if (fail_read || off > skb->len || len > skb->len - off || off + len > sizeof(frame)) return -1;
    memcpy(dst, frame + off, len);
    return 0;
}
#include "royd_iface_account.h"

static unsigned cases;
static void expect(struct __sk_buff skb, int result, uint64_t bytes, uint64_t packets) {
    uint64_t actual_bytes = 0, actual_packets = 0;
    assert(royd_ip_counters(&skb, &actual_bytes, &actual_packets) == result);
    if (result == 1) { assert(actual_bytes == bytes); assert(actual_packets == packets); }
    cases++;
}
int main(void) {
    struct ethhdr* eth = (void*)frame;
    struct iphdr* ip = (void*)(frame + ETH_HLEN);
    struct ipv6hdr* ip6 = (void*)(frame + ETH_HLEN);
    for (unsigned len = 20; len < 65536; len++) {
        memset(frame, 0, 128);
        eth->h_proto = htons(ETH_P_IP); ip->version = 4; ip->ihl = 5;
        ip->tot_len = htons(len);
        struct __sk_buff skb = {.len = ETH_HLEN + len + 12};
        expect(skb, 1, len, 1);  // Ethernet padding is not IP usage.
        skb.len = ETH_HLEN + len - 1;
        expect(skb, -1, 0, 0);
    }
    memset(frame, 0, sizeof(frame));
    eth->h_proto = htons(ETH_P_IP); ip->version = 4; ip->ihl = 5;
    ip->tot_len = htons(60000); ip->protocol = IPPROTO_TCP;
    struct tcphdr* tcp = (void*)(frame + ETH_HLEN + 20); tcp->doff = 8;
    struct __sk_buff skb = {.len = ETH_HLEN + 60000, .gso_segs = 42};
    expect(skb, 1, 60000 + 41 * 52, 42);
    tcp->doff = 4; expect(skb, -1, 0, 0);
    tcp->doff = 8; ip->frag_off = htons(0x2000); expect(skb, -1, 0, 0);
    ip->frag_off = 0; ip->protocol = IPPROTO_UDP;
    expect(skb, 1, 60000 + 41 * 28, 42);
    ip->protocol = IPPROTO_ICMP; expect(skb, -1, 0, 0);
    ip->protocol = IPPROTO_TCP; ip->ihl = 4; expect(skb, -1, 0, 0);
    ip->ihl = 5; ip->version = 6; expect(skb, -1, 0, 0);
    memset(frame, 0, 128); eth->h_proto = htons(ETH_P_IPV6);
    ip6->version = 6; ip6->payload_len = htons(1280);
    skb.len = ETH_HLEN + 1320 + 12; skb.gso_segs = 0;
    expect(skb, 1, 1320, 1);
    skb.len = ETH_HLEN + 1319; expect(skb, -1, 0, 0);
    skb.len = ETH_HLEN + 1320; skb.gso_segs = 10; ip6->nexthdr = IPPROTO_TCP;
    tcp = (void*)(frame + ETH_HLEN + 40); tcp->doff = 5;
    expect(skb, 1, 1320 + 9 * 60, 10);
    ip6->nexthdr = IPPROTO_UDP; expect(skb, 1, 1320 + 9 * 48, 10);
    ip6->nexthdr = IPPROTO_ROUTING; expect(skb, -1, 0, 0);
    skb.gso_segs = 0; ip6->payload_len = 0; expect(skb, -1, 0, 0);
    eth->h_proto = htons(ETH_P_ARP); expect(skb, 0, 0, 0);
    skb.len = 10; expect(skb, -1, 0, 0);
    skb.len = 60; fail_read = 1; expect(skb, -1, 0, 0);
    printf("Interface IP-byte packet contracts passed: %u cases\n", cases);
}
