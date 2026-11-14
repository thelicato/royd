# Known limitations

royd is experimental. Local validation of Android 15 does not yet constitute a supported release. Final clean-build, application/network, endurance and reference-host acceptance remain pending. See [the completion checklist](android15-completion.md) and [support policy](support-policy.md).

## Android 15 scope

The active baseline is x86_64, standard graphical, software rendering, low-memory resource mode, privileged rootful Docker and one IPv4 `eth0`. Other Android versions, arm64, alternative profiles, host GPU, Podman and rootless operation have separate validation requirements. A configured option is not a compatibility guarantee.

Printing, Bluetooth, NFC, camera, telephony and other optional peripherals may be omitted. Their absence is intentional for this baseline; arbitrary forced links into unsupported features are not all qualified. The image uses software reference security components and provides no hardware-backed key-protection claim. Privileged operation is not isolation from hostile container root. Read [security](security.md) before deployment.

## Responsiveness and visual quality

Earlier development images produced WebView/Launcher focus ANRs and startup SystemServer pre-watchdogs. Available captures do not establish every cause: some pre-trigger thread/checker data was not retained, and late samples cannot establish the duration or cause of an earlier wait. Exact historical causal closure is deferred and accepted as a limitation. These failures are not claimed to be fixed or harmless.

Final-candidate acceptance still rejects every retained ANR, input timeout and pre-watchdog, including failures followed by process recovery. Normal timeout policy, credential durability, permission checks and workload assertions remain unchanged. A new occurrence requires investigation; a successful later repetition does not erase a failure.

Sampled blank Settings transitions have been attributed to a stock opaque splash above advancing app buffers, and specific hand-off waits to BufferQueue backpressure with later progress. This explains those captures only. Faded/blank video samples and hand-off warnings remain in retained evidence. Successful scrcpy encoding/decoding and discrete screenshots do not guarantee continuous visual quality, bounded launch latency or universal deadlock absence. See [graphics](graphics.md).

## Networking and storage

IPv4 application DNS/HTTPS, UID policies and the scoped quota/accounting backend have dedicated qualification procedures. This does not establish IPv6-only, multi-NIC/default, VPN/private-DNS, forwarding or general browser compatibility. Platform TLS trust remains unchanged; optional public test endpoints can fail independently of the runtime.

Quota enforcement and sampled alerts are separate. Notifications have scheduling/Binder delay; a sampled threshold is not packet-path enforcement. Listener registration is owned by netd and requires explicit re-registration after service replacement. Continuous enforcement throughout restart windows and unflushed crash/host-power-loss history durability are unqualified. Public integer NetworkStats APIs do not support Ethernet history; recorder validation does not change that API.

Storage totals describe the `/data` filesystem's shared backing pool, not reserved per-instance allocation or a disk quota. Persisted restart checks do not qualify image upgrades or sudden host power loss.

## Host and resource requirements

The kernel must provide the required Binder/binderfs and enabled network-backend facilities; [hardware contract](hardware-contract.md) describes the current requirements. Missing host-global GPU/memory tracepoint and CPU-frequency data is reported as unavailable rather than measured zero. Container-scoped tracing/energy attribution is not implied by a successful boot.

No minimum RAM figure, performance-mode speed advantage or cross-runtime performance comparison is claimed. Measurements must state the exact host, image, limits, profiles and workload. An external comparator requesting host-global changes must be run on a disposable separate kernel or under a separately reviewed common containment policy. See [benchmarking](benchmarking.md).
