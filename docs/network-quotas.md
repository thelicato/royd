# Android 15 container network quotas and alerts

Status: implementation contract, not implemented or qualified quota/alert support. Scope is the Android 15 x86_64 standard graphical software baseline in privileged rootful Docker, with one OCI-provisioned IPv4 `eth0`. Existing UID, metered and Data Saver packet controls do not implement interface byte quotas or byte-threshold alerts.

## Established source boundary

The pinned [netd BandwidthController](https://android.googlesource.com/platform/system/netd/+/8542734a0dd1db395a4d42aae09c37f3c3c3e7a1/server/BandwidthController.cpp) installs legacy filter/quota rules. Fresh logs show filter-table initialisation failing before quota-extension availability can be established. `setGlobalAlert` nevertheless records the requested size; a later call therefore updates the nonexistent `/proc/net/xt_quota/globalAlert` entry. An absent proc entry is a consequence of failed setup, not evidence that normal routing or all UID accounting fails. Failed installation must not become successful backend state.

In pinned Connectivity commit `64cd443febd3ee0fd5c90b47089d82b96850c1e9`:

- [NetworkStatsService](https://android.googlesource.com/platform/packages/modules/Connectivity/+/64cd443febd3ee0fd5c90b47089d82b96850c1e9/service-t/src/com/android/server/net/NetworkStatsService.java) registers a global alert, receives `onQuotaLimitReached`, schedules a statistics poll and rearms the alert. Statistics-provider notifications remain a separate part of registration.
- [netd.c](https://android.googlesource.com/platform/packages/modules/Connectivity/+/64cd443febd3ee0fd5c90b47089d82b96850c1e9/bpf/progs/netd.c) updates UID maps in its cgroup packet path. Interface statistics have separate xt_bpf/tc update sites. A working UID map is not proof of working interface totals.
- [NetworkStatsFactory](https://android.googlesource.com/platform/packages/modules/Connectivity/+/64cd443febd3ee0fd5c90b47089d82b96850c1e9/service-t/src/com/android/server/net/NetworkStatsFactory.java) defines interface summaries as IP-layer, boot-monotonic accounting. Link counters from `/proc/net/dev` are a transport control, not a drop-in replacement for those semantics.

Framework `NetworkManagementService` retains permission checks and its active quota/alert state. NetworkPolicyManager uses interface limits independently of UID firewall decisions. Preserve those distinctions and stock handling outside the strict container gate.

## Local accounting witness

On 21 October 2026, frozen image `012e0e603b1b` passes ordinary-UID DNS, literal/hostname nonce HTTP and full independent pre/post runtime checks in both Docker DNS modes. Read-only snapshots around the workload show:

| Evidence | Bridge | Embedded DNS |
| --- | --- | --- |
| Ordinary UID | 10096 | 10096 |
| New UID-map RX/TX bytes | 1608 / 1095 | 1608 / 1095 |
| Namespace-local `eth0` link RX/TX increase | 2593 / 2191 | 2411 / 1828 |
| Interface-map entries before/after | 0 / 0 | 0 / 0 |

The interface map reports `OK`, its content header is present, and its interface-name mapping resolves `eth0`. This is an empty readable map, not a failed dump. Target-UID `eth0` rows also advance in the active UID stats map; raw UID aggregates are not substituted for interface totals. Both nonce GETs reach the fixture, identity/OCI configuration remain unchanged and complete logs/inspect are retained. Link totals include different layer semantics and other traffic, so equality with UID bytes is neither expected nor used as an assertion.

This reproduces a missing interface-accounting prerequisite, not broken ordinary transport. [Native interface readers](https://android.googlesource.com/platform/packages/modules/Connectivity/+/64cd443febd3ee0fd5c90b47089d82b96850c1e9/service-t/native/libs/libnetworkstats/BpfNetworkStats.cpp) sum this map and initialise an empty result to zero; that is source-path evidence, not a separate live TrafficStats API measurement. No quota, alert callback, forced counter insertion or manual host-network reconfiguration is exercised here. Diagnostic assessment records interface accounting as failed, separately from passing DNS/runtime controls.

## Required implementation invariants

Patch `0065` implements the first accounting path, pending rebuilt-image acceptance. Under the strict gate, netd creates private pinned TCX ingress/egress links on the existing `eth0`, verifies each program, link, direction and current-namespace query, then activates a private selector. These links do not replace clsact qdiscs or other links and survive framework/netd restarts. Existing counters are not reset. Mismatching or detached pins and interface replacement are rejected rather than adopted by recycled ifindex; recreate the disposable instance for a replacement device. Setup failure is fatal to netd and remains visible. Actual program loading and link attachment establish capability, not the kernel version or Kconfig alone. TCX is an additional baseline requirement, not a claim that older hosts now qualify.

The hooks count IPv4/IPv6 IP lengths, excluding Ethernet headers, padding, ARP and loopback. Supported TCP/UDP GSO/GRO adds the replicated IP/transport headers using the kernel's segment count and actual IPv4/TCP header lengths, not a fixed-MTU estimate. Unsupported segmented protocols/IPv6 extension chains, malformed headers, failed packet reads or missing counter entries latch a sticky unavailable flag. They do not drop packets or masquerade as zero usage. Interface byte/packet increments are atomic across CPUs. Normal UID accounting keeps its existing independent AOSP semantics.

Ingress is measured before subsequent tc/netfilter/socket-UID policy drops; egress is measured after socket-UID denial but before subsequent tc/qdisc/driver drops. System, raw and unassociated packets reaching these hooks are not excluded by a UID firewall exemption. Selected-interface xt_bpf and legacy ingress-account actions omit only their duplicate accounting update; other interfaces and all packet-policy decisions remain unchanged. Physical CLAT semantics, forwarding, non-Ethernet/VLAN devices, IPv6-only and multi-interface operation remain outside this baseline's acceptance. Accounting begins when both verified links are activated, not at namespace creation.

The permission-checked `dumpsys netd` status requires both links still attached in the current namespace, readable counter state and a zero error latch. Runtime assertions require that status and the bounded activation marker. A readable map alone remains insufficient; live workloads must establish increasing native interface totals, UID/link controls and real fixture receipts. The ordinary test APK additionally records public TrafficStats total/own-UID byte readings before/after traffic without clearing caches or gaining permissions. Those totals are partial interface-map witnesses, not qualification of every interface or persisted usage. This patch does not repair legacy quota installations, UID-history RCU availability or threshold callbacks.

Netd's startup cleanup and physical-network lifecycle leave `eth0`'s clsact qdisc alone under the same gate, because the private links neither need nor own it. Other interfaces and stock behaviour outside the gate remain unchanged. Attachment and packet traversal follow Linux's [TCX link implementation](https://github.com/torvalds/linux/blob/v6.8/kernel/bpf/tcx.c) and [network-device hooks](https://github.com/torvalds/linux/blob/v6.8/net/core/dev.c).

Enable a replacement only with `ROYD_CONTAINER=1` and a SELinux enforcement-interface probe failing with exactly `ENOENT`. Other probe failures retain stock behaviour. Keep all maps, control state and packet attachments inside the instance's existing private BPF/cgroup/network boundaries. Do not load host modules, change host tracing/sysctl policy, create fake proc files, replace unowned filters/qdiscs or alter OCI addresses, main routes, DNS, MTU or interface provisioning.

### Accounting first

- Establish real ingress and egress IP-byte accounting for the selected interface before using its totals for notifications or quotas. Cover ordinary and system UIDs; a system-UID firewall exemption must not silently exempt traffic from interface totals or limits.
- Define packet traversal, blocked-packet ordering, segmentation/offload accounting and CLAT exclusions against the actual AOSP code. Prevent duplicate updates if legacy or tc accounting is also active. A cgroup-only counter must not be called an interface counter without proving its coverage.
- Preserve independent UID statistics, recorder behaviour and existing packet policies. Raw UID-map advancement alone does not qualify UID history or persisted usage.
- Detect unavailable maps, malformed entries, counter regression and interface disappearance/reuse. Never turn an unavailable read into measured zero use. Do not key a new device's policy solely by a recycled ifindex or silently transfer an exhausted allowance to it.

### Quotas are enforcement

Enforce the selected interface's shared RX/TX budget in the packet path. A userspace polling loop, delayed callback, logical network hiding or disabled getter is not a hard quota. Specify the treatment of the threshold-crossing packet and any permitted overshoot before claiming enforcement. Retain packet-policy ordering and prove that another CPU, UID, direction or socket cannot obtain an independent full allowance.

Shared BPF values are concurrently accessible across CPUs; [kernel map documentation](https://docs.kernel.org/bpf/map_hash.html#concurrency) describes the synchronisation boundary. A lookup followed by an unlocked decrement is insufficient. Map replacement atomicity does not itself prove an atomic multi-field budget update. Verify control-plane changes versus packet updates, integer overflow/underflow and actual verifier/helper compatibility. Do not select support by a kernel-version guess or grant additional host tracing privileges.

### Alerts are notifications

Deliver real one-shot global/interface threshold notifications with the existing framework identities and permission checks. Preserve statistics polling/rearming and provider notifications. Alerts must not themselves become packet drops. If notification delivery is sampled from a private event map, document its scheduling delay separately from in-kernel quota enforcement; do not claim instantaneous delivery.

Use generation-aware registration/removal so a delayed event cannot fire for a replacement alert. Do not issue Binder callbacks while holding a lock that callback handling may re-enter. Rearm from a defined accounting baseline, not an old pending event. Service/framework restart and interface changes must not resurrect stale notifications or silently discard a still-enforced quota.

| Operation | Required result | Failure boundary |
| --- | --- | --- |
| Install/update quota | Acknowledged packet-path budget, defined update point | Keep coherent prior state or fail closed; no successful getter-only update |
| Remove quota | Stop enforcement and remove its associated alert consistently | Do not report removal while the old limit remains active |
| Install/update interface alert | Require the existing quota and use the requested new threshold | Do not retain an old threshold as a successful update |
| Register global alert | Arm a new window and preserve provider registration | Do not record failed legacy installation as an armed replacement |
| Remove/rearm alert | Cancel stale generations; one notification for each new crossing | No duplicate, stale or fabricated notification |

Keep each API layer's existing caller checks, absence/duplicate semantics and errors. Review invalid values and legacy sentinels explicitly rather than inventing one common interpretation across quota and alert APIs. Map/open/update/attach errors must remain visible and must not acknowledge unenforced security state. Define restart ownership and rollback before wiring the new backend into service calls.

## Required qualification

1. **Accounting:** controlled ordinary-UID upload/download on the actual metered interface, matching application receipts, advancing native/UID/interface counters and independent namespace-local link controls. Include system traffic, blocked traffic, segmentation and concurrent flows; specify loopback and unrelated-traffic inclusion/exclusion against the relevant API semantics. Do not require equality between counters with different layer semantics.
2. **Quota:** positive allowance, threshold crossing, denied subsequent packets with zero new fixture receipts, shared two-UID/bidirectional/concurrent enforcement, update/removal and restored traffic. A timeout without a packet/receipt control does not prove enforcement.
3. **Alerts:** real global and interface callbacks, no premature callback below threshold, exactly one crossing notification, correct identity, rearm, cancellation, stale-generation rejection and coexistence with quota enforcement. A marker or forced callback is not delivery evidence.
4. **Failure/security:** exact gate combinations, denied callers, invalid inputs, unavailable or failing maps, failed installation/update/removal, backend restart, interface withdrawal/reuse and preservation of stock behaviour outside the gate. Never exercise host-global deletion or substitute a fake kernel interface.
5. **Rebuilt image:** actual applied-source contracts, canonical CI, Android rebuild/import and fresh runtime/log/inspect evidence. Repeat bridge/embedded DNS, UID/metered/Data Saver regressions, link recovery, persistence/restarts and timed scrcpy as appropriate to changed inputs. Preserve failures and security assertions.

No implementation checkbox closes from this contract alone. The first implementation milestone is a verified accounting source with defined packet coverage, followed by quota enforcement and notification integration. Active tethering/forwarding, VPNs, IPv6-only or multi-interface policies, other Android versions and broader kernel support remain separate scope.
