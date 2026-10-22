// Pinned android-15.0.0_r36 fragments for the append-only packet-policy patch.
DEFINE_BPF_MAP_RO_NETD(stats_map_A, HASH, StatsKey, StatsValue, STATS_MAP_SIZE)
DEFINE_BPF_MAP_RO_NETD(stats_map_B, HASH, StatsKey, StatsValue, STATS_MAP_SIZE)
DEFINE_BPF_MAP_NO_NETD(iface_stats_map, HASH, uint32_t, StatsValue, IFACE_STATS_MAP_SIZE)
DEFINE_BPF_MAP_RO_NETD(uid_owner_map, HASH, uint32_t, UidOwnerValue, UID_OWNER_MAP_SIZE)
DEFINE_BPF_MAP_RO_NETD(uid_permission_map, HASH, uint32_t, uint8_t, UID_OWNER_MAP_SIZE)
DEFINE_BPF_MAP_NO_NETD(ingress_discard_map, HASH, IngressDiscardKey, IngressDiscardValue,
                       INGRESS_DISCARD_MAP_SIZE)

DEFINE_BPF_MAP_RO_NETD(data_saver_enabled_map, ARRAY, uint32_t, bool,
                       DATA_SAVER_ENABLED_MAP_SIZE)

// iptables xt_bpf programs need to be usable by both netd and netutils_wrappers
// selinux contexts, because even non-xt_bpf iptables mutations are implemented as
// a full table dump, followed by an update in userspace, and then a reload into the kernel,

DEFINE_UPDATE_STATS(iface_stats_map, uint32_t)
DEFINE_UPDATE_STATS(stats_map_A, StatsKey)
DEFINE_UPDATE_STATS(stats_map_B, StatsKey)

// both of these return 0 on success or -EFAULT on failure (and zero out the buffer)
static __always_inline inline int bpf_skb_load_bytes_net(const struct __sk_buff* const skb,
                                                         const int L3_off,

static __always_inline inline int bpf_owner_match(struct __sk_buff* skb, uint32_t uid,
                                                  const struct egress_bool egress,
                                                  const struct kver_uint kver) {
    if (is_system_uid(uid)) return PASS;

    if (skip_owner_match(skb, egress, kver)) return PASS;

    return PASS;
}

DEFINE_XTBPF_PROG("skfilter/egress/xtbpf", AID_ROOT, AID_NET_ADMIN, xt_bpf_egress_prog)
(struct __sk_buff* skb) {
    // Clat daemon does not generate new traffic, all its traffic is accounted for already
    // on the v4-* interfaces (except for the 20 (or 28) extra bytes of IPv6 vs IPv4 overhead,
    // but that can be corrected for later when merging v4-foo stats into interface foo's).
}

// WARNING: Android T's non-updatable netd depends on the name of this program.
DEFINE_XTBPF_PROG("skfilter/ingress/xtbpf", AID_ROOT, AID_NET_ADMIN, xt_bpf_ingress_prog)
(struct __sk_buff* skb) {
    // Clat daemon traffic is not accounted by virtue of iptables raw prerouting drop rule
    // (in clat_raw_PREROUTING chain), which triggers before this (in bw_raw_PREROUTING chain).
    // It will be accounted for on the v4-* clat interface instead.
}

DEFINE_SYS_BPF_PROG("schedact/ingress/account", AID_ROOT, AID_NET_ADMIN,
                    tc_bpf_ingress_account_prog)
(struct __sk_buff* skb) {
    if (is_received_skb(skb)) {
        // Account for ingress traffic before tc drops it.
        uint32_t key = skb->ifindex;
    }
}
