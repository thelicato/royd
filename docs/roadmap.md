# Roadmap

This roadmap is ordered by implementation dependency rather than release date. A milestone is complete only when its behaviour can be reproduced from this repository.

## Android 15 baseline completion

The active acceptance scope is Android 15 x86_64, standard graphical image, software rendering, the low-memory resource profile and privileged rootful Docker. It is not completion of every item below or a claim of general device compatibility.

1. **Implementation:** the reproduced Storage Settings crash (`0063`) and idle Tethering hardware failure (`0062`) have rebuilt-image qualification for the active baseline. Shared `/data` capacity is not a per-instance quota. Investigate recurring diagnostics by their affected invariant; logical network hiding, successful commands and an artificially empty error log do not establish correct behaviour.
2. **Rebuilt-image qualification:** freeze an exact image, then pass fresh boot, app lifecycle, IPv4 DNS/HTTP/native and WebView HTTPS, packet-policy controls, persistence/restarts and timed scrcpy checks. Retain failures and exercise a defined application/network/restart soak. Earlier-image results do not automatically qualify a changed image.
3. **Build and host acceptance:** record a clean baseline build and reviewed reference-host/kernel evidence, including Binder isolation, OCI configuration and documented limitations. Incremental local builds and lightweight CI alone do not establish support.

On 21 October 2026, rebuilt image `ed6dd897088f` with patch `0063` passes fresh baseline qualification, ordinary-UID storage API/loaded Settings checks, full Data Saver and native/WebView HTTPS/certificate-rejection checks in both Docker DNS modes, and a five-minute scrcpy workload with full post-runtime checks. Container restart/recreation also preserves named state; framework-only restart passes with preserved state and verified native host-power tracing. Fresh 20-round native/WebView HTTPS runs pass in both DNS modes after a test-only visible-window correction; the original display-timeout failure remains retained. This closes the reproduced storage and idle-Tethering blockers and the named HTTPS repetition gate locally. The first storage run remains failed because its post-check selected an existing task's Storage page; an independently retained rerun passes after the host-only About-phone selector correction. Broader applications and longer application/network/restart soaks, clean-build/reference-host review and legacy byte-quota/threshold-alert support remain open. Active physical tethering is not qualified. Other Android versions, arm64, host GPU, alternative profiles and privilege reduction are deferred. A preliminary external comparison still requires independent comparator safety/functionality and matched configuration under [benchmarking](benchmarking.md#competitive-performance-comparison), not completion of the wider version matrix.

The subsequent `0064` image `012e0e603b1b` passes fresh full qualification, five-minute scrcpy and 20 native/WebView HTTPS rounds in each DNS mode. Delayed isolated-UID retirement emits one container-local cleanup marker per long-run log without attempting the host-global legacy write. One original supervising shell exits 143 after its inner bridge result passes; its cause remains unestablished and its evidence is retained separately. Both fresh confirmation commands exit0 and all 40 assessments replay successfully. This closes the scoped legacy cleanup isolation and rebuilt-image gate locally, not complete CPU-accounting isolation. Storage, packet-policy and restart results above remain specific to the earlier image pending final-image requalification.

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
- [ ] Investigate and qualify remaining legacy-table-dependent policies, including byte quotas and threshold alerts; cgroup-BPF UID, metered and Data Saver evidence does not qualify these separate capabilities.
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
