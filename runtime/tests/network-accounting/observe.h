#ifndef ROYD_TEST_OBSERVE_H
#define ROYD_TEST_OBSERVE_H
#include <linux/types.h>
struct observe_config { __u32 ifindex, port; };
struct observe_stats {
    __u64 skbs, segments, gso_skbs, raw_bytes, other_ip_skbs, errors;
};
#endif
