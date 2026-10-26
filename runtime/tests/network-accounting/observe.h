#ifndef ROYD_TEST_OBSERVE_H
#define ROYD_TEST_OBSERVE_H
#include <linux/types.h>
struct observe_config { __u32 ifindex, port, tcp_port; };
struct observe_stats {
    __u64 skbs, segments, gso_skbs, raw_bytes, other_ip_skbs, errors;
};
// Header metadata only, no packet payload. Overflow invalidates the observation.
#define TCP_RECORD_LIMIT 4096
struct tcp_record {
    __u32 skb_len, ip_len, ip_total, tcp_len, sequence, gso_size, gso_segs;
    __u32 flags, source, destination, source_port, destination_port;
};
#endif
