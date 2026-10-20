// Pinned android-15.0.0_r36 fragments for the append-only packet-policy patch.
DEFINE_BPF_MAP_RO_NETD(data_saver_enabled_map, ARRAY, uint32_t, bool,
                       DATA_SAVER_ENABLED_MAP_SIZE)

// iptables xt_bpf programs need to be usable by both netd and netutils_wrappers
// selinux contexts, because even non-xt_bpf iptables mutations are implemented as
// a full table dump, followed by an update in userspace, and then a reload into the kernel,

static __always_inline inline int bpf_owner_match(struct __sk_buff* skb, uint32_t uid,
                                                  const struct egress_bool egress,
                                                  const struct kver_uint kver) {
    if (is_system_uid(uid)) return PASS;

    if (skip_owner_match(skb, egress, kver)) return PASS;

    return PASS;
}
