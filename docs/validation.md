# Runtime validation

The runtime validation scripts are intended to turn host testing into a repeatable step before royd publishes compatibility or memory claims. They use Docker and commands already present inside Android, so ADB is not required.

## Single-instance smoke test

Build, package, and import `royd:dev`, then run:

```sh
make runtime-smoke-test
```

The test creates a temporary Docker volume and privileged container, waits for `sys.boot_completed=1`, then checks:

- Android completed boot.
- `/dev/binder`, `/dev/hwbinder`, and `/dev/vndbinder` are character devices.
- royd private binderfs is mounted at `/dev/royd-binderfs`.
- the royd binderfs readiness message reached container logs.
- `ro.config.low_ram` is enabled.
- the royd logcat forwarding service is running.

Graphics assertions follow the selected Android release contract. Android 15 validates its AIDL allocator V2, stable-C mapper V5, ANGLE-over-Pastel renderer and composer3 properties without requiring the legacy `ro.hardware.gralloc`, `ro.hardware.egl`, or `ro.hardware.hwcomposer` selectors.

The Android 15 client-only composer advertises `PRESENT_FENCE_IS_NOT_RELIABLE` because it has no physical scan-out timestamp and RenderEngine completes without an acquire fence. SurfaceFlinger consequently disables presentation-latency tracking for this display. Runtime qualification requires `service.sf.present_timestamp=0` and rejects invalid-present-fence diagnostics.

During early Android 15 boot, container-specific WTF reports can precede publication of the DropBox Binder service. ActivityManager skips only that pre-publication persistence attempt under the explicit container-without-SELinux gate, preventing the missing service from recursively generating more WTFs. Runtime qualification requires the service after boot and rejects the recursive missing-DropBox diagnostic.

Android 15 netd avoids querying its unavailable legacy iptables tether counters while the container has never configured a forwarding pair. This removes a repeated, expensive NetworkStats failure from idle non-tethering instances without hiding failures after tethering has created counter state. Runtime qualification rejects the recurring tether-stat diagnostic.

When the host kernel has no TCP inet-diag handler, Android 15 recognises the exact `SOCK_DIAG_BY_FAMILY` `ENOENT` response under the container gate and caches that unsupported state. This prevents repeated IPv4 and IPv6 socket-cleanup dumps from waiting for 300 ms receive timeouts. Other netlink errors and all non-container behaviour remain unchanged. Runtime qualification rejects the former unexpected-message and timeout diagnostics.

During Android 15 boot, framework and modular services can request managers before their Binder services are published, while hardware-specific managers can remain intentionally absent. Under the explicit container gate, `SystemServiceRegistry` suppresses only the resulting pre-boot WTF reports and retains the normal `null` lookup result. Post-boot reporting remains enabled. Runtime qualification rejects these diagnostics and requires the essential JobScheduler and UI mode services after boot.

The Android 15 product does not advertise Ethernet or USB-host hardware. Under the container gate, Tethering therefore reports Ethernet tethering as unsupported without resolving the absent Ethernet manager. Docker's OCI-provided `eth0` remains outside Android's Ethernet stack. Products that advertise either feature and non-container Android environments retain the stock manager probe. Runtime qualification rejects missing-service WTF records while allowing warning-only lookups from optional applications.

Android 15 continues writing `/data/system/packages.list` under the container gate, but skips its SELinux file-creation context lookup and assignment because the container has no active SELinux policy or file-context database. Other Android environments retain the stock context setup and cleanup. Runtime qualification requires a non-empty package list and rejects its former SELinux-context WTF records.

Android 15 does not start its debug-only CPU monitor when the container host exposes no CPU frequency policy directories. The exact container-without-SELinux gate and missing cpufreq capability are both required, so systems with usable frequency statistics and all non-container environments retain the stock monitor and fatal diagnostics. Runtime qualification rejects the former CpuMonitorService WTF record.

Because the OCI entrypoint starts Android 15 at second-stage init, init recreates first-stage init's `/mnt` tmpfs under the explicit container gate. Vold therefore retains a writable runtime staging area after Android remounts its root read-only, allowing `/storage/emulated` and user 0 storage to mount normally. Runtime qualification verifies the tmpfs, FUSE mount and user directory, and rejects the former read-only mount failure.

During early Android 15 boot, SystemServer waits for audio policy initialisation before publishing ActivityManager. Under the explicit container gate, AudioPolicyService checks for the unpublished Binder service without waiting and defers its UID-observer registration. Its existing conservative active and top-state fallback remains in force until a later policy query retries registration. Runtime qualification requires ActivityManager and both audio services after boot, and rejects ActivityManager wait loops and SystemServer pre-watchdog events.

SystemServer also publishes sensor privacy after it waits for audio policy initialisation. Under the same container gate, AudioPolicyService defers its privacy-listener registration while that service is absent and uses the native manager's stock disabled fallback. A later audio policy evaluation takes a strong reference to the guarded policy object under the service mutex, then releases the mutex before retrying the state query and listener registration. Runtime qualification requires sensor privacy after boot and rejects its former audioserver wait loop.

Android 15 runtime assertions also require the AIDL Codec2 software store to expose H.264 video and Opus audio encoders. The product selects Stagefright's local AIDL GraphicBufferSource path for encoder input surfaces because it does not install the remote Codec2 input-surface or legacy OMX services. Codec2 uses its BufferQueue and gralloc-backed BLOB pools because OCI does not provide Android's ION or dma-buf system heap. The memfd allocator supports the software encoder's surface and BLOB output usage, and the runtime check records a short non-empty H.264 display capture to verify the complete SurfaceFlinger-to-Codec2 path. These components provide the default scrcpy streaming codecs without requiring host media hardware.

The Android 15 graphical product installs only AOSP's app-widget feature declaration rather than the broad handheld hardware declaration. Runtime assertions require the resulting AppWidget service, unlock the display, select Home and confirm that the same Launcher3 process remains alive across a stability interval before recording the display capture.

Android 15 delegates `/sys/fs/cgroup/royd` to the Android system UID while leaving Docker's cgroup root unchanged. Android init moves into `/sys/fs/cgroup/royd/init`, leaving the delegated root free to enable the cgroup-v2 memory controller for `lmkd` and Android process groups. Libprocessgroup removes the namespace-absolute `/royd` prefix before resolving task attributes against that controller root, preventing duplicated paths. Netd attaches Android's network BPF programs to the delegated root rather than rejecting the non-standard cgroup path. Runtime assertions verify the memory-controller delegation, a non-zero Launcher `memory.low`, PID 1 and `system_server` membership, and a running netd. They also reject duplicated cgroup roots, launch the WebView shell and require `system_server` to remain alive, covering the isolated-process group path used by WebView and other app zygotes.

On Android 15 containers, init retains the OCI stdout and stderr descriptors while still attaching stdin to `/dev/null`. Repository-owned startup diagnostics, the boot watchdog and the `logcat` forwarding service write through PID 1, so `docker logs` does not depend on ADB or a host-side logging supervisor.

Android 15 also installs a final main-table policy fallback before Android's terminal unreachable rule. Earlier Android VPN, explicit, local and default-network rules remain authoritative, while fresh replies through Docker's OCI-provided `eth0` route continue to work after boot. Runtime qualification verifies this path with a new host-side ADB connection.

The temporary container and volume are removed when the test exits, including after failure.

## Two-instance smoke test

Run:

```sh
make runtime-multi-test
```

This starts two containers at the same time with separate `/data` volumes, waits for both to boot, and applies the same runtime assertions to each instance. It confirms that both containers can create and use their own binderfs mounts concurrently. Use `make runtime-binder-isolation-test` for the stronger device-identity test that verifies each private binderfs instance received a distinct kernel Binder device set.

For manual testing with ADB, the repository also provides:

```sh
docker compose -f runtime/compose.multi.yaml up -d
```

The two instances expose ADB on `127.0.0.1:5555` and `127.0.0.1:5556`.

## Timeouts and image selection

The default boot timeout is 180 seconds. Override it when testing slower hosts:

```sh
ROYD_BOOT_TIMEOUT=300 make runtime-smoke-test
```

The Make targets use `royd:dev`. The scripts can also be invoked directly with another image:

```sh
./runtime/scripts/smoke-test.sh example/royd:test
./runtime/scripts/multi-instance-test.sh example/royd:test
```

## Recording a reference host

Before an image is available, capture the kernel-side baseline with:

```sh
make runtime-kernel-evidence
```

This does not qualify a host, but it makes the later boot evidence comparable and records unknown Kconfig values explicitly.

A known-good result should record at least:

```text
royd commit:
Android baseline:
image architecture:
host distribution:
host kernel and kernel-evidence contract:
Docker version:
cgroup mode:
CPU:
RAM:
GPU device passed to container, if any:
single-instance smoke test:
two-instance smoke test:
```

Record the exact container memory limit, display profile, graphics mode, settling time, and workload alongside any memory measurement. A successful boot is not sufficient evidence for a minimum RAM claim.

## Automated reference-host report

Once `royd:dev` is available on a real host, collect the host metadata and both runtime smoke-test results in one Markdown report:

```sh
make runtime-reference-report
```

Save it directly with:

```sh
ROYD_REPORT_OUTPUT=reference-host.md make runtime-reference-report
```

The report is generated even when a smoke test fails, and the command returns non-zero when either smoke test fails. See [`reference-hosts.md`](reference-hosts.md) for the evidence contract.
## Runtime qualification

After an OCI image passes the basic smoke tests, run the persisted qualification gate:

```sh
make runtime-qualification
make runtime-qualification-report
```

Qualification records boot, Docker health, runtime assertions, security mode, SurfaceFlinger, container-log forwarding, ADB, and Binder isolation in `.work/runtime-results`. See [`runtime-qualification.md`](runtime-qualification.md).
