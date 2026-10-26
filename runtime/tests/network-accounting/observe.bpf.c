// Optional test-only pass-through observer, never installed in the Android image.
#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <linux/udp.h>
#include <linux/tcp.h>
#include "observe.h"
#define SEC(name) __attribute__((section(name), used))
#define __uint(name, value) int (*name)[value]
#define __type(name, type) type *name
struct { __uint(type, BPF_MAP_TYPE_ARRAY); __uint(max_entries, 1);
    __type(key, __u32); __type(value, struct observe_config); } observe_config SEC(".maps");
struct { __uint(type, BPF_MAP_TYPE_ARRAY); __uint(max_entries, 2);
    __type(key, __u32); __type(value, struct observe_stats); } observe_records SEC(".maps");
struct { __uint(type, BPF_MAP_TYPE_ARRAY); __uint(max_entries, 2);
    __type(key, __u32); __type(value, __u64); } tcp_counts SEC(".maps");
struct { __uint(type, BPF_MAP_TYPE_ARRAY); __uint(max_entries, 2 * TCP_RECORD_LIMIT);
    __type(key, __u32); __type(value, struct tcp_record); } tcp_records SEC(".maps");
static void* (*lookup)(void*, const void*) = (void*)BPF_FUNC_map_lookup_elem;
static long (*load)(const struct __sk_buff*, __u32, void*, __u32) = (void*)BPF_FUNC_skb_load_bytes;
static __attribute__((always_inline)) inline int collect(struct __sk_buff* skb, __u32 direction) {
    __u32 zero = 0;
    struct observe_config* cfg = lookup(&observe_config, &zero);
    struct observe_stats* stats = lookup(&observe_records, &direction);
    if (!cfg || !stats || cfg->ifindex != skb->ifindex) return -1;
    struct ethhdr eth;
    if (load(skb, 0, &eth, sizeof(eth))) { __sync_fetch_and_add(&stats->errors, 1); return -1; }
    if (eth.h_proto != __builtin_bswap16(ETH_P_IP) && eth.h_proto != __builtin_bswap16(ETH_P_IPV6)) return -1;
    struct iphdr ip;
    if (cfg->tcp_port && eth.h_proto == __builtin_bswap16(ETH_P_IP)
            && !load(skb, 14, &ip, sizeof(ip)) && ip.version == 4 && ip.ihl == 5 && ip.protocol == 6) {
        struct tcphdr tcp;
        if (load(skb, 34, &tcp, sizeof(tcp))) { __sync_fetch_and_add(&stats->errors, 1); return -1; }
        if (__builtin_bswap16(tcp.source) == cfg->tcp_port || __builtin_bswap16(tcp.dest) == cfg->tcp_port) {
            __u64* count = lookup(&tcp_counts, &direction);
            if (!count) { __sync_fetch_and_add(&stats->errors, 1); return -1; }
            __u64 slot = __sync_fetch_and_add(count, 1);
            if (slot >= TCP_RECORD_LIMIT) { __sync_fetch_and_add(&stats->errors, 1); return -1; }
            __u32 key = direction * TCP_RECORD_LIMIT + slot;
            struct tcp_record* r = lookup(&tcp_records, &key);
            if (!r) { __sync_fetch_and_add(&stats->errors, 1); return -1; }
            *r = (struct tcp_record){
                .skb_len = skb->len, .ip_len = ip.ihl * 4, .ip_total = __builtin_bswap16(ip.tot_len),
                .tcp_len = tcp.doff * 4, .sequence = __builtin_bswap32(tcp.seq),
                .gso_size = skb->gso_size, .gso_segs = skb->gso_segs,
                .flags = ((__u8*)&tcp)[13], .source = __builtin_bswap32(ip.saddr),
                .destination = __builtin_bswap32(ip.daddr),
                .source_port = __builtin_bswap16(tcp.source), .destination_port = __builtin_bswap16(tcp.dest),
            };
            return -1;
        }
    }
    struct udphdr udp;
    if (eth.h_proto == __builtin_bswap16(ETH_P_IP) && !load(skb, 14, &ip, sizeof(ip))
            && ip.version == 4 && ip.ihl == 5 && ip.protocol == 17
            && !load(skb, 34, &udp, sizeof(udp))
            && (__builtin_bswap16(udp.source) == cfg->port || __builtin_bswap16(udp.dest) == cfg->port)) {
        __sync_fetch_and_add(&stats->skbs, 1);
        __sync_fetch_and_add(&stats->segments, skb->gso_segs > 1 ? skb->gso_segs : 1);
        __sync_fetch_and_add(&stats->gso_skbs, skb->gso_segs > 1 ? 1 : 0);
        __sync_fetch_and_add(&stats->raw_bytes, skb->len);
    } else {
        __sync_fetch_and_add(&stats->other_ip_skbs, 1);
    }
    return -1; // TCX_NEXT, including every error path. Never change or drop a packet.
}
SEC("tc") int observe_ingress(struct __sk_buff* skb) { return collect(skb, 0); }
SEC("tc") int observe_egress(struct __sk_buff* skb) { return collect(skb, 1); }
char observer_license[] SEC("license") = "GPL";
