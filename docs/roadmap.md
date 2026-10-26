# Roadmap

This roadmap is ordered by implementation dependency rather than release date. A milestone is complete only when its behaviour can be reproduced from this repository.

## Android 15 baseline completion

The active acceptance scope is Android 15 x86_64, standard graphical image, software rendering, the low-memory resource profile and privileged rootful Docker. It is not completion of every item below or a claim of general device compatibility.

1. **Implementation:** the reproduced Storage Settings crash (`0063`) and idle Tethering hardware failure (`0062`) have rebuilt-image qualification for the active baseline. Shared `/data` capacity is not a per-instance quota. Investigate recurring diagnostics by their affected invariant; logical network hiding, successful commands and an artificially empty error log do not establish correct behaviour.
2. **Rebuilt-image qualification:** freeze an exact image, then pass fresh boot, app lifecycle, IPv4 DNS/HTTP/native and WebView HTTPS, packet-policy controls, persistence/restarts and timed scrcpy checks. Retain failures and exercise a defined application/network/restart soak. Earlier-image results do not automatically qualify a changed image.
3. **Build and host acceptance:** record a clean baseline build and reviewed reference-host/kernel evidence, including Binder isolation, OCI configuration and documented limitations. Incremental local builds and lightweight CI alone do not establish support.

On 21 October 2026, rebuilt image `ed6dd897088f` with patch `0063` passes fresh baseline qualification, ordinary-UID storage API/loaded Settings checks, full Data Saver and native/WebView HTTPS/certificate-rejection checks in both Docker DNS modes, and a five-minute scrcpy workload with full post-runtime checks. Container restart/recreation also preserves named state; framework-only restart passes with preserved state and verified native host-power tracing. Fresh 20-round native/WebView HTTPS runs pass in both DNS modes after a test-only visible-window correction; the original display-timeout failure remains retained. This closes the reproduced storage and idle-Tethering blockers and the named HTTPS repetition gate locally. The first storage run remains failed because its post-check selected an existing task's Storage page; an independently retained rerun passes after the host-only About-phone selector correction. Broader applications and longer application/network/restart soaks, clean-build/reference-host review and legacy byte-quota/threshold-alert support remain open. Active physical tethering is not qualified. Other Android versions, arm64, host GPU, alternative profiles and privilege reduction are deferred. A preliminary external comparison still requires independent comparator safety/functionality and matched configuration under [benchmarking](benchmarking.md#competitive-performance-comparison), not completion of the wider version matrix.

The subsequent `0064` image `012e0e603b1b` passes fresh full qualification, five-minute scrcpy and 20 native/WebView HTTPS rounds in each DNS mode. Delayed isolated-UID retirement emits one container-local cleanup marker per long-run log without attempting the host-global legacy write. One original supervising shell exits 143 after its inner bridge result passes; its cause remains unestablished and its evidence is retained separately. Both fresh confirmation commands exit0 and all 40 assessments replay successfully. This closes the scoped legacy cleanup isolation and rebuilt-image gate locally, not complete CPU-accounting isolation. Independent storage API/UI, container restart/recreation and framework-only restart requalification also pass on this image, with preserved named state and verified native host-power tracing. These close the named current-image regression gates, not longer soaks or clean-build/reference-host acceptance.

Independent follow-up runs on `012e0e603b1b` requalify OEM UID denial, metered background denial, the full Data Saver packet matrix and continuous-process IPv4 link-loss/recovery in both DNS modes. All eight test commands record exit0, pass full pre/post runtime and unchanged OCI checks, and replay their saved assessments. The private lane also records exit0 before its outer tool wrapper reports 143; that supervision discrepancy and its unestablished cause remain retained, not labelled a clean outer sequence or Android failure. Byte quotas/threshold alerts, TLS continuity through loss, longer soaks and general host acceptance remain open.

The `0065`/`0066` image `f14a08bffee0` has real ordinary-UID IPv4 interface/public-API counter progress in both DNS modes, preserved framework-restart links/maps/counters and passing fresh baseline, five-minute scrcpy, HTTPS and persistence checks. On 23 October, the corrected test launchers complete 36 observed sleeping-display launches across metered/Data Saver matrices in both DNS modes, with passing saved packet/process-state/restoration/runtime assessments. Private link recovery also passes. Both Data Saver outer helpers return2 after their completed Android runs because the agent edited the running helper; independent result replay passes without relabelling those outer commands. Original fixture failures and a separate missing CPU-residency marker pre-check remain retained. Subsequent source review corrects the latter's invalid mandatory boot-marker criterion: the reader reports on demand. Two fresh frozen-script runtime checks pass with unavailable residency explicitly reported; the original read/log ordering remains unknown. Broader accounting acceptance, UID history, quotas/alerts and final build/host acceptance remain open.

The `0067`/`0068` image `618fa11930c9` restores real RCU-protected stats-map rotation and recorded ordinary-UID Ethernet history in both DNS modes. Both history commands, saved assessment replay, fresh baseline, UID/metered/Data Saver policies, link recovery, native/WebView HTTPS and container/framework restart checks pass. History durability, broader accounting and quotas/alerts remain open. A valid 15-digit Android ID exposed a restart-fixture width assumption; focused contracts, full CI and a fresh framework-restart run pass after accepting the actual unpadded representation.

The `618fa11930c9` five-minute scrcpy workload remains failed: it records eight `mediaextractor` seccomp aborts at the libcutils memfd probe and then a Settings ringtone-preparation crash, despite a decodable MP4.

The rebuilt `0069` image `787018adad5f` closes that scoped media blocker locally. Five own-asset media preparations and five Sound Settings entries pass with stable service identity and active seccomp/no-new-privileges. Fresh persisted qualification and a five-minute scrcpy workload pass, including full post-runtime checks and complete recording decode. Recorded UID history, OEM UID policy and native/WebView HTTPS checks pass in both DNS modes; storage and container/framework restarts also pass. An initial display-timeout storage fixture failure stays failed; a host-only activity-refresh correction passes focused contracts, full CI and fresh storage validation. See [media shared memory](media-sandbox.md) for scope and retained evidence.

Broader graphical acceptance remains open: the original bridge-history log contains one WebView-shell focus timeout near an intentional force-stop, although the script manifest passes and no formal `am_anr` follows. A fresh sequential bridge-history confirmation passes without reproducing it. The exact cause is unestablished; retain the raw diagnostic and investigate lifecycle responsiveness without generic filtering. Existing media/scrcpy success does not close this independent issue or establish support/comparison readiness.

On 26 October, `787018adad5f` also passes the separate flushed UID-history durability gate across Docker restart/recreation and framework-only restart. All five phase assessments replay with identical recorded buckets before app relaunch, unchanged private seed/UID, normal access denial and full pre/post runtime checks. Native framework power tracing remains verified. The first inactive-directory fixture failure is retained; a corrected host fixture selects the reported APEX-data directory. This closes the scoped history-persistence item locally, with no image change. Broader accounting, byte quotas/threshold alerts, the intermittent focus timeout, longer soaks and clean-build/reference-host acceptance remain open.

A separate 26 October native UDP accounting run on unchanged `787018adad5f` passes exact IPv4 RX/TX totals for root raw sockets, UID1000 with zero effective capabilities, real bidirectional UDP segmentation and overlapping root/system flows. Both TCX hooks observe segmentation; loopback adds no `eth0` traffic. Full pre/post runtime and observer-detachment checks pass, with unchanged production maps/links, SystemServer and OCI identity. These are native init-cgroup workers, not a new ordinary-APK or multi-CPU witness. TCP segmentation and blocked-packet accounting remain open before full accounting acceptance; quotas/alerts, the earlier focus timeout, longer soaks and final build/host review remain open.

The subsequent native TCP gate on `787018adad5f` passes a verified 1 MiB stream in each direction for UID1000 and for overlapping root/system flows, after all five UDP controls. Independent segment-size/sequence/header assessment matches exact product counters, including variable ACK traffic and 32/40-byte TCP headers, with real aggregation at both hooks. Full pre/post runtime, attachment removal and unchanged OCI/qdisc/identity checks pass. This closes the scoped lossless IPv4 TCP segmentation witness without rebuilding Android. Blocked-packet ordering, quota/alert implementation, the earlier focus timeout, longer soaks and final build/host review remain open; actual multi-CPU stress and general lossy TCP remain unqualified.

The ordinary-UID denied-packet gate on unchanged `787018adad5f` passes two persistent background service/socket identities through baseline, OEM target denial, independent control and restoration. During denial, all 64 sends fail with EPERM and no target request reaches the fixture; 64 pushed datagrams count as ingress without app delivery, with zero egress. All other app phases have exact RX/TX64 packets/78,592 IP bytes, and five native controls, full runtime, restoration, zero fixture drops and observer removal pass. This closes the named local IPv4 accounting prerequisite, not quota/alert implementation or general support. Failed TCP repetition (duplicate376 bytes, trigger unknown), host-fixture queue overflow and new APK/API/command-publication attempts remain retained; bounded traffic, real Android API compilation and atomic commands are test corrections. Wider TCP/host coverage, the earlier focus diagnostic, longer soaks and final build/host acceptance remain open.

## 1. Independent AOSP baseline

- [x] Pin Android 8.0 through 17 AOSP releases, with Android 15 as the default baseline.
- [x] Remove external Android container manifests, device trees, vendor trees, and patch repositories from the build path.
- [x] Add repository-owned `royd_x86_64` and `royd_arm64` products.
- [x] Add legacy and transitional build/product/partition families for Android 8.0 through 10.
- [x] Add a Java 8/Python 2-capable legacy AOSP builder and version-independent binderfs allocator ABI.
- [x] Implement a repository-owned memfd-backed `libcutils` compatibility path without requiring an out-of-tree ashmem host module.
- [ ] Validate legacy shared-memory compatibility on clean Android 8.0 through 10 builds and representative workloads.
- [x] Add static and AOSP-resolved build-contract preflight checks.
- [x] Define explicit ext4 partition and copy-out requirements for OCI assembly.
- [x] Add repository-owned vendor integration and Binder allocation.
- [x] Add a repository-owned local AOSP patch mechanism.
- [x] Package the generated AOSP root and partition images into an OCI root filesystem.
- [ ] Run the AOSP-resolved build-contract preflight on a clean synced checkout.
- [ ] Build both royd products from clean AOSP checkouts using the clean-build matrix.
- [ ] Boot Android as PID 1 in an OCI container on a documented reference host.
- [ ] Record a known-good build and boot validation from the independent baseline.

## 2. Container-owned Binder setup

- [x] Add binderfs-first startup integration.
- [x] Implement the Binder allocation helper inside this repository.
- [x] Expose private binderfs devices at the conventional Android device paths.
- [x] Emit actionable Binder compatibility diagnostics to container output.
- [ ] Validate binderfs-only hosts with no pre-created Binder devices.
- [x] Add a two-container Binder device-identity isolation test.
- [ ] Run the Binder isolation test successfully on documented reference hosts.

## 3. Container-native Android hardware surface

- [x] Stop inheriting AOSP emulator product definitions and `emulator_vendor.mk`.
- [x] Add royd-owned x86_64 and arm64 board configuration.
- [ ] Build both royd-owned board configurations from a clean AOSP checkout and resolve any missing HAL or image requirements.
- [x] Add a repository-owned memfd gralloc module and version-matched AOSP composer bridge for the software path.
- [ ] Validate the software graphics path with clean builds and real SurfaceFlinger boots across representative Android generations.
- [x] Implement optional Android 10+ host GPU rendering through explicit `/dev/dri` access with AOSP Mesa/minigbm backends.
- [x] Define initial graphical and headless-oriented HAL profiles with explicit image identity.
- [ ] Validate the exact runtime HAL/service set and selected graphics backend for both profiles across representative Android generations and real hosts.
- [x] Make runtime display parameters take effect before graphics startup through the royd-owned OCI entrypoint and early-init bootstrap.

## 4. Container-native logging and diagnostics

- [x] Add `logcat` forwarding to container stdout and stderr.
- [x] Keep Android `/init` as PID 1 through an `exec` hand-off from the royd OCI entrypoint.
- [x] Add Binder, cgroup, and graphics startup diagnostics.
- [x] Add a reproducible reference-host report.
- [x] Add checksummed reference-host qualification bundles with policy-staleness and tamper verification.
- [x] Add a timed scrcpy streaming-stability gate with retained recording and host/container evidence for Android 15 graphical qualification.
- [x] Add first-class ADB-over-TCP configuration, Docker health checks, and host validation tooling.
- [x] Add ADB, container-log, health, and SurfaceFlinger checks to the persisted runtime qualification gate.
- [x] Add a bounded boot watchdog and standalone diagnostic snapshot that write failed-boot evidence directly to container logs.
- [x] Retain Docker logs, inspect and state evidence when a container never starts and has no health state, without relaxing qualification gates.
- [x] Make the Android 15 graphical capture check honour MediaStore indexing and exact-owned cleanup instead of generating private-path scan failures.
- [x] Verify normal `adb logcat` alongside container log forwarding on the local Android 15 baseline with retained simultaneous live-marker evidence.
- [ ] Confirm boot failures are understandable from `docker logs` on reference hosts.

## 5. Reproducible runtime examples

- [x] Add a minimal `docker run` example.
- [x] Add a configurable Docker Compose example.
- [x] Add Compose lifecycle Make targets.
- [x] Add persistent `/data` and ADB configuration.
- [x] Add retained Android 15 persistent-data validation across Docker restart and container recreation, with full per-phase runtime assertions.
- [x] Correct and qualify ordinary-UID internal-storage capacity and the loaded Storage Settings dashboard on the shared OCI backing pool, without fabricating a physical device or per-instance quota.
- [x] Add reproducible framework-only restart validation with readiness reset/recovery, persisted-state checks and restricted native host-power tracing.
- [x] Requalify container restart/recreation and framework-only restart on the `0063` Android 15 baseline, with preserved named state and verified framework-native power tracing.
- [x] Implement strict container-gated omission of the legacy host-global UID CPU-stat cleanup write, preserving local history removal, reads and stock behaviour outside the gate.
- [x] Qualify the rebuilt `0064` image through delayed isolated-UID retirement, full runtime checks and retained on-demand policy evidence, without exercising a real host-global accounting deletion.
- [x] Requalify OEM UID denial, metered background denial, full Data Saver and same-process IPv4 link recovery on the `0064` image in both Docker DNS modes, with full runtime and OCI checks.
- [x] Requalify storage API/UI, container restart/recreation and framework-only restart on the `0064` image, with preserved state, full runtime checks and verified native host-power tracing.
- [ ] Validate longer restart/application soaks and review framework-restart evidence on documented reference hosts.
- [x] Retain a ten-minute local Android 15 Settings/scroll/Home stream with full pre/post checks and supplementary process/readiness/health observations.
- [x] Add bounded Android 15 memory-controller delegation recovery for transient early external exec processes, retaining domain-controller constraints and explicit persistent-failure diagnostics.
- [ ] Validate broader early-exec timing and host/runtime combinations; indefinite root-cgroup occupants remain unsupported by bounded recovery.
- [x] Add multiple-instance Compose and smoke-test workflows.
- [x] Add persisted runtime qualification results and compatibility-matrix integration.
- [x] Add controlled application-UID literal-IPv4 HTTP validation with a WebView JavaScript callback and retained network evidence.
- [x] Add controlled ordinary-app DNS and framework-network diagnostics with direct UDP/HTTP controls and retained failing evidence.
- [x] Avoid an absent optional FRP-service lookup during container app installation while preserving configured/published FRP and installer security checks.
- [x] Implement IPv4 `eth0` OCI network publication and per-network resolver integration without taking over interface provisioning.
- [x] Keep framework host-clock writes read-only before enabling automatic time suggestions through network publication.
- [x] Avoid NetworkMonitor's unadvertised Wi-Fi lookup during OCI network recovery without bypassing validation or missing-service assertions.
- [ ] Extend and qualify IPv6, multi-NIC/default-route policies and network transitions beyond the IPv4 bridge baseline.
- [x] Qualify controlled ordinary-app IPv4 DNS, hostname HTTP, default-network callbacks and unchanged OCI configuration on Docker bridge and embedded DNS, including post-boot link recovery.
- [x] Add and locally qualify ordinary-UID public IPv4 DNS/HTTPS with platform trust, self-signed certificate rejection, Docker/embedded DNS and retained pre/post runtime evidence.
- [x] Add ordinary-UID WebView HTTPS document/DOM and untrusted-certificate qualification alongside native TLS controls, with retained independent runtime and OCI evidence.
- [x] Run the WebView HTTPS qualification on the baseline image in Docker bridge mode and retain passing real-runtime evidence.
- [x] Run WebView HTTPS qualification with Docker embedded DNS and retain passing real-runtime evidence.
- [x] Add same-instance ordinary-UID native/WebView HTTPS repetition with fresh app processes, exact round identities, retained failures and per-round runtime/OCI stability checks.
- [x] Locally qualify 20 native/WebView HTTPS rounds in each Docker DNS mode on the frozen `0063` Android 15 image, preserving the failed original run and full independent post-runtime checks.
- [x] Add reproducible continuous-process ordinary-UID IPv4 link-loss/recovery validation with ordered default-network callbacks, fresh-name DNS and nonce HTTP, retained phase evidence and independent runtime/OCI checks.
- [x] Add two-UID stock OEM deny-chain qualification with BPF-map evidence, real UDP/HTTP denial, unaffected control traffic and restoration.
- [x] Add a Data Saver activation gate distinguishing shell-command success from actual policy/BPF state, with retained failures, restoration and independent ordinary-app controls.
- [x] Scope the netpolicy shell's optional Wi-Fi lookup to available hardware in the explicit container environment, retaining policy commands and strict post-boot diagnostics.
- [x] Add a two-UID ordinary-background-service metered-denial diagnostic with packet-level controls, independent policy/map evidence and verified restoration.
- [x] Implement gated cgroup-BPF user/admin metered denial for the OCI publisher's actual interface, retaining stock UID decisions and independent legacy-policy failures.
- [x] Implement gated global Data Saver activation and packet enforcement with background, user-exemption/revocation and foreground controls plus restoration. Qualify the rebuilt image independently.
- [x] Make ordinary network-policy launchers wait for window focus and locally qualify sleeping-display metered/Data Saver packet matrices in both DNS modes, retaining failed attempts and supervision errors.
- [x] Correct the CPU-residency pre-check's mandatory boot-marker assumption using the pinned reader/CPU-selection contracts; explicitly report unavailable residency and retain real CPU-time/error checks. The original failed run remains failed, and its exact read/log ordering is not recoverable from the saved log.
- [ ] Investigate and qualify remaining legacy-table-dependent policies, including byte quotas and threshold alerts; cgroup-BPF UID, metered and Data Saver evidence does not qualify these separate capabilities.
- [x] Implement strictly gated sampled global byte-threshold notification from verified private interface counters, with fresh baselines, one-shot generations, callback lock separation, visible failures and focused source contracts. This is notification source, not packet enforcement or rebuilt-image acceptance.
- [ ] Rebuild and qualify actual global callbacks, threshold boundaries, rearming/cancellation, framework polling/providers and restart behaviour; a marker or committed counter is insufficient.
- [ ] Implement and qualify packet-path byte quotas and associated interface-alert integration; do not derive hard limits from the global sampler.
- [x] Reproduce the interface-accounting prerequisite with real ordinary-UID traffic in both DNS modes and define the [quota/alert implementation contract](network-quotas.md), without claiming a backend fix.
- [x] Qualify native root/raw and system-UID IPv4 UDP accounting, real UDP segmentation at both TCX hooks, overlapping bidirectional flows and loopback exclusion with exact counters and full runtime/attachment evidence. This does not qualify actual multi-CPU stress or Android system-service identities.
- [x] Locally qualify native IPv4 TCP segmentation with exact verified stream ranges/digests, independent segment-size/header totals including ACKs, actual options/aggregation at both hooks and overlapping root/system flows. This does not qualify lossy TCP or actual multi-CPU stress.
- [x] Establish the named local IPv4 interface-accounting prerequisites: ordinary-UID interface/API progress in both DNS modes, framework-restart link/map continuity, native UDP/TCP and loopback controls, and real ordinary-UID denied-packet boundaries. This is the scoped baseline foundation for quota/alert implementation, not broader workload/kernel support or actual multi-CPU quota acceptance.
- [x] Implement private, strictly container-gated `eth0` ingress/egress IP accounting with attachment ownership, duplicate-update prevention and focused packet/native contracts. Rebuilt-image and broader accounting acceptance remain separate from this source milestone.
- [x] Restore real RCU-protected detailed stats-map rotation and locally qualify recorded ordinary-UID Ethernet history in both DNS modes, with access denial, repeated polls and independent runtime evidence.
- [x] Locally qualify explicitly flushed recorded UID-history across Docker restart/recreation and framework-only restart on the bridge, with unchanged UID/private seed, exact canonical buckets, ordinary access denial and full runtime/native power evidence. Unflushed crash/power-loss, upgrades and other network modes remain unqualified.
- [x] Fix and qualify the reproduced mediaextractor memfd sandbox failure and resulting Sound Settings crash, preserving scoped syscall restrictions and full crash-history assertions.
- [x] Implement a strictly gated, required media shared-memory policy addition with stock/vendor composition, real Minijail/kernel contracts and a zero-permission application/Sound Settings qualification runner. Rebuilt-image and scrcpy qualification remain separate from this source milestone.
- [x] Reject retained application ANR and unresponsive-window history before and after Android 15 runtime workloads, including native/WindowManager-only reports and recovered processes. This closes the qualification gap, not the original timeout cause.
- [ ] Diagnose the retained WebView-shell focus-event timeout near lifecycle force-stop and qualify responsiveness; passing command manifests and absence of a formal ANR event do not resolve it.
- [ ] Qualify broader network-aware applications, additional WebView pages and certificate/hostname failure modes, and network lifecycle soaks; named public endpoints are not general Internet compatibility.
- [ ] Validate the multiple-instance example on a documented reference host.
- [ ] Record the minimum known-good host kernel configuration.

The repository now captures a versioned kernel/Kconfig evidence file in every reference-host qualification bundle. The minimum-known-good item remains open until a successful real Android boot establishes which recorded configuration is actually sufficient.

## 6. Low-memory Android profiles

- [x] Enable Android low-RAM behaviour with PSI-based `lmkd`.
- [x] Add named display profiles.
- [x] Add repeatable memory reports and memory-limit sweeps.
- [x] Add standard and minimal build-time Android image profiles.
- [x] Add standard-versus-minimal comparison reporting.
- [ ] Record repeatable idle and workload memory benchmarks on a reference host.
- [ ] Tune `lmkd` and background process behaviour against container memory limits.
- [x] Expand the minimal package policy conservatively with version-family rules, a protected core package guard, and immutable policy identity.
- [x] Require generated memory evidence to record the exact image/profile policy, display configuration, and named workload before figures are published.
- [x] Add independent Android 15 low-memory and performance resource profiles selected before boot without rebuilding the image.
- [x] Define a preliminary Android 15 external-comparison gate distinct from release acceptance and wider-version validation.
- [x] Add a product-neutral single-trial measurement harness with explicit phase boundaries, owned disposable resources and retained failure evidence.
- [x] Inspect a pinned Android 15 comparator without executing it, recording installed provenance and host-global side effects that block unreviewed shared-host execution.
- [ ] Independently qualify a matching comparator and retain repeated same-host comparison results using the common measurement procedure.

## 7. Privilege reduction

- [x] Add a versioned deterministic experimental capability inventory with exact Docker/Compose/CLI parity and kernel-visible security evidence.
- [x] Run the existing smoke, multi-instance, benchmark, CLI, and report tooling through selectable security modes.
- [x] Add a security-mode comparison report with captured failure diagnostics.
- [ ] Validate the experimental mode on a known-good reference host.
- [ ] Remove capabilities that are not demonstrated requirements.
- [ ] Record any required seccomp, LSM, device, cgroup, or system-path exceptions.
- [ ] Promote the smallest validated OCI configuration to the default.
- [x] Document runtime differences across Docker, Podman, and other supported engines.
- [x] Evaluate rootless operation separately.

## 8. Optional Go CLI

- [x] Add host capability checks.
- [x] Add run, list, shell, logs, stop, and remove workflows.
- [x] Keep command output transparent about Docker operations.
- [x] Keep every core runtime workflow usable without the CLI.
- [x] Add ADB convenience commands while keeping direct host ADB workflows available.

## Container hardware ownership

Completed in the current baseline:

- repository-owned binderfs allocation and conventional Binder device exposure
- explicit host preflight checks
- early-boot cgroup, PSI, and DRM diagnostics
- AOSP SwiftShader libraries selected as the software EGL baseline
- runtime assertion of the selected software graphics mode

Remaining work:

- validate the royd-owned board configurations with clean AOSP builds and remove any unnecessary GSI defaults revealed by those builds
- validate the repository-owned allocator and AOSP composer bridge with clean Android builds and real display output
- validate the first complete boot without emulator-specific vendor services
- qualify the implemented Android 10+ Mesa/minigbm host-GPU backends on real DRM drivers and keep only combinations that pass runtime qualification

## OCI image contract

Implemented:

- canonical tags derived from the pinned AOSP ref, image profile, HAL profile, and architecture
- development aliases kept separate from canonical identity
- immutable `/royd-release` metadata inside packaged root filesystems
- archive SHA-256 manifests verified before Docker import
- OCI and royd-specific image labels
- post-import image contract inspection without Android boot

## Next milestones
- Validate every pinned Android version from 8.0 through 17 with resolved AOSP configuration, clean x86_64 and arm64 builds, OCI packaging, and boot smoke tests.
- Validate the memfd-backed legacy shared-memory path for Android 8.0 through 10 on modern host kernels and identify any direct-ioctl compatibility gaps.

## Build validation automation

- [x] Add a canonical lightweight CI entry point.
- [x] Add hosted CI for repository contracts without downloading AOSP.
- [x] Add a version and architecture compatibility matrix report.
- [x] Add strict matrix mode for dedicated AOSP validation hosts.
- [ ] Run the strict matrix against real synced Android 8.0 through 17 trees.
- [x] Add resumable clean-build orchestration and persistent per-tuple build results.
- [x] Integrate clean-build and package evidence into the compatibility matrix.
- [ ] Run the clean-build matrix on dedicated build hosts for Android 8.0 through 17.

## Runtime qualification automation

- [x] Add persisted per-tuple runtime qualification results.
- [x] Add a resumable multi-version and multi-architecture runtime qualification matrix.
- [x] Add Docker health, runtime, graphics, logging, ADB, security, and Binder-isolation stages.
- [x] Integrate runtime evidence into the Android compatibility matrix.
- [ ] Run qualification on successfully built and imported Android 8.0 through 17 images.
- [ ] Review reference-host, memory, and runtime evidence before promoting any tuple to supported.
