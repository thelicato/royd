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

Android 15's optional GPU-memory collector attaches a system-wide tracepoint without a container filter. The reference host lacks `gpu_mem/gpu_mem_total`, so initialisation fails even though the pinned BPF program exists; the resulting accounting would not be container-scoped on a host exposing the tracepoint either. With `ROYD_CONTAINER=1` and an `ENOENT` probe for `/sys/fs/selinux/enforce`, royd leaves this collector and its Perfetto source inactive and makes `dumpsys gpu --gpumem` explicitly report unavailable accounting, not zero usage. Ordinary driver statistics, GPU work accounting, ANGLE/SwiftShader rendering, dump permissions and BPF loading remain unchanged. Existing SELinux interfaces and every other probe error retain stock behaviour. Qualification requires the bounded skip marker, the unavailable status and graphical driver-statistics response, and rejects the former attachment and dependent-tracer failures. A container-scoped GPU-memory collector remains future work.

Android 15's audio startup assertions attribute shared-tag ServiceManager wait messages to the live audioserver PID or earlier audioserver PIDs identified by native log records. A cameraserver wait during framework replacement is not evidence that audioserver blocked. Full container logs retain other callers' diagnostics for separate investigation.

Android 15's SystemSuspend service normally releases `zygote_kwl` through `/sys/power/wake_unlock`, even when its suspend loop uses blocking fallback descriptors. The [Linux kernel wake-lock table](https://github.com/torvalds/linux/blob/master/kernel/power/wakelock.c) is global, not container-owned; releasing an unknown name returns `EINVAL`. Under the explicit container-without-SELinux gate, royd keeps native wake locks in the stock in-process counter, retains Binder tokens and statistics, and avoids opening either kernel wake-lock control or releasing the host's zygote lock. Init also skips writes to the four exact `/sys/power/{state,wakeup_count,wake_lock,wake_unlock}` paths, covering stock zygote restart actions. Other init writes, stock failures and all non-container behaviour remain unchanged. Qualification requires the suspend Binder services, native PowerManager wake-lock statistics, the in-process mode marker and a live service with no descriptors to those four controls, and rejects power-control access failures. After rebuilding, validate a zygote restart in a disposable container as well as normal qualification; require recovery and the bounded init skip marker without host power writes. Do not restart an older image's zygote to test this guard.

The Android 15 client-only composer advertises `PRESENT_FENCE_IS_NOT_RELIABLE` because it has no physical scan-out timestamp and RenderEngine completes without an acquire fence. SurfaceFlinger consequently disables presentation-latency tracking for this display. Runtime qualification requires `service.sf.present_timestamp=0` and rejects invalid-present-fence diagnostics.

During early Android 15 boot, container-specific WTF reports can precede publication of the DropBox Binder service. ActivityManager skips only that pre-publication persistence attempt under the explicit container-without-SELinux gate, preventing the missing service from recursively generating more WTFs. Runtime qualification requires the service after boot and rejects the recursive missing-DropBox diagnostic.

Android 15 netd avoids querying its unavailable legacy iptables tether counters while the container has never configured a forwarding pair. This removes a repeated, expensive NetworkStats failure from idle non-tethering instances without hiding failures after tethering has created counter state. Runtime qualification rejects the recurring tether-stat diagnostic.

When the host kernel has no TCP inet-diag handler, Android 15 recognises the exact `SOCK_DIAG_BY_FAMILY` `ENOENT` response under the container gate and caches that unsupported state. This prevents repeated IPv4 and IPv6 socket-cleanup dumps from waiting for 300 ms receive timeouts. Other netlink errors and all non-container behaviour remain unchanged. Runtime qualification rejects the former unexpected-message and timeout diagnostics.

During Android 15 boot, framework and modular services can request managers before their Binder services are published, while hardware-specific managers can remain intentionally absent. Under the explicit container gate, `SystemServiceRegistry` suppresses only the resulting initialisation-time WTF reports and retains normal lookup results. It checks both stock device boot completion and `sys.royd.framework_ready`, which SystemServer resets at construction and SystemServiceManager sets after successful `PHASE_BOOT_COMPLETED` callbacks. This also covers zygote restarts, where stock `sys.boot_completed` remains set throughout framework initialisation. Stock boot properties and restart detection remain unchanged; reporting resumes once both barriers are complete. Qualification requires readiness, both lifecycle markers and essential JobScheduler and UI mode services, while retaining its rejection of missing-service WTFs. Restart validation must observe a new framework readiness cycle and wait for current-framework services, not rely on stale device boot completion.

The Android 15 product does not advertise Ethernet or USB-host hardware. Under the container gate, Tethering therefore reports Ethernet tethering as unsupported without resolving the absent Ethernet manager. Docker's OCI-provided `eth0` remains outside Android's Ethernet stack. Products that advertise either feature and non-container Android environments retain the stock manager probe. Runtime qualification rejects missing-service WTF records while allowing warning-only lookups from optional applications.

Android 15 continues writing `/data/system/packages.list` under the container gate, but skips its SELinux file-creation context lookup and assignment because the container has no active SELinux policy or file-context database. Other Android environments retain the stock context setup and cleanup. Runtime qualification requires a non-empty package list and rejects its former SELinux-context WTF records.

Android 15 does not start its debug-only CPU monitor when the container host exposes no CPU frequency policy directories. The exact container-without-SELinux gate and missing cpufreq capability are both required, so systems with usable frequency statistics and all non-container environments retain the stock monitor and fatal diagnostics. Runtime qualification rejects the former CpuMonitorService WTF record.

Android 15 keeps ActivityManager's PSI low-memory detector available on normal Linux hosts without granting `system_server` `CAP_SYS_RESOURCE`. Under the container gate, its stock 1-second thresholds are doubled together with the tracking window to meet Linux's unprivileged 2-second-window rule without changing the pressure ratios. `lmkd` retains its separate stock PSI monitors and vmstat fallback. Runtime qualification requires the container-specific detector mode and rejects PSI registration failures.

Android 15's optional ActivityManager OOM listener and lmkd BPF memory-event listener use host-global tracepoints without a container filter. On the reference host, lmkd opens the tracepoint ID successfully but its system-wide `perf_event_open` fails with `EACCES`; system UID 1000 also cannot read the OOM tracepoint ID. The [Linux perf security model](https://www.kernel.org/doc/html/latest/admin-guide/perf-security.html) explains the host tracing privilege boundary. Under the explicit container-without-SELinux gate, royd leaves ActivityManager's OOM thread stopped and returns through lmkd's stock vmstat reclaim fallback before any BPF wait or attachment. PSI monitoring, cgroup memory controls and lmkd kill notifications remain unchanged. Kernel OOM event attribution and tracepoint-based direct-reclaim timing remain unavailable; host-wide tracing privileges and perf sysctls are not changed. Stock behaviour outside the gate remains unchanged. Qualification requires both container markers, the stock vmstat selection marker and a running lmkd, and rejects the former OOM/reclaim attachment failures.

Android 15 supports independent `low-memory` and `performance` resource modes from one image. The entrypoint validates the selected mode and writes its framework, Dalvik and per-app memcg properties before init starts. Under the container gate, init merges that file before publishing immutable boot properties. Per-app memcg remains explicit in both modes because AOSP otherwise defaults it to the low-RAM setting, which would disable royd's per-process `memory.low` policy in performance mode. Runtime qualification checks the selected mode, low-RAM state, per-app memcg and complete heap policy. Performance mode remains a benchmark candidate rather than a performance claim.

Android 15's system files live in the OCI root overlay rather than separate system-partition mounts. Under the container gate, `artd` treats only that root overlay as the system partition for artefact placement. This returns the same conservative global dalvik-cache result as ART's upstream error fallback without emitting a service exception for every system APK. Writable `/data` mounts and stock Android overlay remounts retain their normal classification. Runtime qualification rejects the former missing-fstab artefact diagnostics.

Android 15 normally enables fs-verity on redundant copies of package, permission, role, user and shortcut metadata after each atomic write. The container storage does not support the enabling ioctl. Under the container gate, the system-server `FileIntegrity` helper skips that best-effort protection while retaining the primary and reserve-copy writes. Direct APK, font and app-facing fs-verity paths remain unchanged. Runtime qualification rejects the former repeated metadata protection failures.

Android 15 creates `recent_tasks` and `recent_images` lazily on the first task or custom-icon write. Fresh-container evidence shows unlocked, accessible user storage and successful task persistence while the unused icon directory remains absent. Under the container-without-SELinux gate, TaskPersister cleanup treats only a failed listing with `lstat` `ENOENT` and an existing directory parent as empty. It reports that mode once, rechecks later listings, and preserves atomic writes and obsolete-file deletion. Missing user storage, dangling symlinks, permission failures and other errors retain stock diagnostics, as do all other Android environments. Graphical qualification flushes the workload's task queue with `am write`, requires non-empty task XML and persisted task IDs, and requires the marker when the icon directory is uncreated. Qualification rejects recents-directory access errors without filtering the container log.

Android 15's stock task profiles still contain cgroup-v1 placement actions for CPU, cpuset and block I/O scheduling. Android creates their configured mount-point directories even when no legacy hierarchy is mounted, so libprocessgroup tests each root's `cgroup.procs` interface under the container gate. When that interface is absent with `ENOENT`, it omits only the controller's `JoinCgroup` actions instead of repeatedly attempting nonexistent `/dev/cpuctl`, `/dev/cpuset` and `/dev/blkio` paths. Timer slack, scheduler and other actions in the same profiles still run, and a mounted legacy hierarchy remains usable. The delegated cgroup-v2 memory hierarchy and stock behaviour outside the container gate are unchanged. Runtime qualification requires the bounded skip marker and rejects the former missing legacy-controller diagnostics.

Android 15 backports the upstream ServiceManager correction that applies the legacy context-manager proxy's blocking exemption to the native `IServiceManager` proxy used for actual lookups. This keeps ServiceManager's required synchronous calls from triggering a false `FLAG_ONEWAY` WTF during `SystemServer` context construction while leaving blocking-call warnings enabled for every other Binder proxy. Runtime qualification rejects the former ServiceManager stack specifically.

Android 15's [StatsD Binder service](https://android.googlesource.com/platform/packages/modules/StatsD/+/refs/tags/android-15.0.0_r36/statsd/src/main.cpp) requests caller SIDs by default. With kernel SELinux unavailable, the [Binder driver](https://code.googlesource.com/linux/torvalds/linux/+/abcbd3bfbbfe97a8912d0c929d4aa18f50d9bc52/drivers/android/binder.c) fails to obtain the security context and rejects transactions with `EINVAL`, including metadata dumps and framework stats-puller registration. Under the explicit container gate, statsd disables only that transport SID request. StatsService's UID, permission and SID authorisation remain unchanged; SID-protected subscription operations still deny non-root callers without a SID. Other Android environments retain the stock SID request. Runtime qualification requires `statsd` to be running, the `stats` service to exist, its `dumpsys stats --metadata` response to contain the upstream metadata header, and its container SID marker to be present. It rejects the specific stats-puller registration and IStatsd descriptor failures while leaving unrelated Binder diagnostics visible.

Because the OCI entrypoint starts Android 15 at second-stage init, init recreates first-stage init's `/mnt` tmpfs under the explicit container gate. Vold therefore retains a writable runtime staging area after Android remounts its root read-only, allowing `/storage/emulated` and user 0 storage to mount normally. Runtime qualification verifies the tmpfs, FUSE mount and user directory, and rejects the former read-only mount failure.

Privileged containers share the host's fusectl connection list even though their Android mounts live in separate mount namespaces. Under the container gate, vold therefore matches fusectl connection IDs against FUSE mounts visible in its own `/proc/self/mountinfo` before writing an abort control. Multi-instance qualification verifies that one container's storage reset cannot disconnect another container's `/storage/emulated` mount.

During early Android 15 boot, SystemServer waits for audio policy initialisation before publishing ActivityManager. Under the explicit container gate, AudioPolicyService checks for the unpublished Binder service without waiting and defers its UID-observer registration. Its existing conservative active and top-state fallback remains in force until a later policy query retries registration. Runtime qualification requires ActivityManager and both audio services after boot, and rejects ActivityManager wait loops and SystemServer pre-watchdog events.

SystemServer also publishes sensor privacy after it waits for audio policy initialisation. Under the same container gate, AudioPolicyService defers its privacy-listener registration while that service is absent and uses the native manager's stock disabled fallback. A later audio policy evaluation takes a strong reference to the guarded policy object under the service mutex, then releases the mutex before retrying the state query and listener registration. Runtime qualification requires sensor privacy after boot and rejects its former audioserver wait loop.

Android 15's ANGLE plus SwiftShader software backend disables SurfaceFlinger's eager RenderEngine shader-cache priming. On the reference build, priming 120 shaders occupied the software renderer for about 20 seconds, withheld the default display and triggered SystemServer's pre-watchdog. Shaders still compile on demand, while host-GPU and other Android graphics backends retain their stock priming policy. Runtime qualification requires the property override and continues to reject pre-watchdog events.

Android 15 runtime assertions also require the AIDL Codec2 software store to expose H.264 video and Opus audio encoders. The product selects Stagefright's local AIDL GraphicBufferSource path for encoder input surfaces because it does not install the remote Codec2 input-surface or legacy OMX services. Codec2 uses its BufferQueue and gralloc-backed BLOB pools because OCI does not provide Android's ION or dma-buf system heap. The memfd allocator supports the software encoder's surface and BLOB output usage, and the runtime check records a short non-empty H.264 display capture to verify the complete SurfaceFlinger-to-Codec2 path. These components provide the default scrcpy streaming codecs without requiring host media hardware.

## scrcpy streaming stability

After runtime qualification passes, validate the host ADB, scrcpy server, H.264 encoder and changing UI stream together with:

```sh
make runtime-scrcpy-stability-test
```

The default 30-second test starts a fresh container and data volume, publishes ADB on a random loopback port, uses an isolated ADB server, records a headless H.264 scrcpy session, and repeatedly opens Settings, scrolls and returns Home. It rejects an early scrcpy exit or an empty recording, and runs full runtime assertions before and after the workload. Format-2 evidence records `POST_RUNTIME_STATUS` and retains `post-runtime.log` alongside the recording, scrcpy/workload/container logs and inspect output, even when post-workload assertions fail. Format-1 recordings remain historical streaming evidence but do not satisfy the strengthened reference-bundle gate. Evidence is written under `.work/scrcpy-stability`; select a fresh directory with `ROYD_SCRCPY_OUTPUT_DIR` to preserve existing results.

Settings previously requested absent Wi-Fi and USB managers on every Home-page refresh, producing post-boot SystemServiceRegistry WTFs. Under the explicit container-without-SELinux gate, the device-name controller omits its Wi-Fi lookup and hotspot-SSID update only when Wi-Fi is not advertised; global device-name persistence and Bluetooth handling remain unchanged. SettingsLib's charger helper omits its USB lookup only when both USB-host and USB-accessory features are absent and Android is not an emulator. The secure warning setting, supported-hardware paths and all stock behaviour outside the gate remain unchanged. Runtime assertions continue rejecting every SystemServiceRegistry WTF, including those from Settings; no generic reporting or log filtering is changed. After rebuilding, require a passing post-workload streaming result and check device-name editing without Wi-Fi.

The About-phone Wi-Fi MAC controller separately requested the absent Wi-Fi manager when opening `android.settings.DEVICE_INFO_SETTINGS`. Under the same container-without-SELinux gate and absent Wi-Fi feature, omit that lookup and retain the controller's existing unavailable state. Do not fabricate a MAC address or change supported-hardware lookups, lifecycle handling or framework reporting. Android 15 graphical runtime assertions now open About phone, require the Settings and system-server processes to remain stable, return Home and recheck all SystemServiceRegistry WTFs after the workload. Rebuild Android before treating this strengthened assertion as validation of the fix.

Android 15's optional GPU-work collector attempts a system-wide `power/gpu_work_period` tracepoint attachment and accounts only by host GPU ID and UID, without a container filter. With `ROYD_CONTAINER=1` and the kernel SELinux enforcement interface absent with `ENOENT`, omit collector initialisation and statsd puller registration. Require one `ROYD: not starting host-global GPU work tracing` marker and an explicit unavailable response from `dumpsys gpu --gpuwork`, not fabricated zero usage. Driver statistics, rendering and behaviour outside that gate remain unchanged. Rebuild before qualification of this policy; GPU work and memory accounting remain unavailable until container-scoped collectors are implemented and validated.

This proves that one timed stream remained healthy on the tested host. It does not measure interactive latency or establish an encoder-throughput claim.

The Android 15 graphical product installs only AOSP's app-widget feature declaration rather than the broad handheld hardware declaration. Runtime assertions require the resulting AppWidget service, unlock the display, select Home and confirm that the same Launcher3 process remains alive across a stability interval before recording the display capture.

Android 15 delegates `/sys/fs/cgroup/royd` to the Android system UID while leaving Docker's cgroup root unchanged. Android init moves into `/sys/fs/cgroup/royd/init`, leaving the delegated root free to enable the cgroup-v2 memory controller for `lmkd` and Android process groups. Libprocessgroup removes the namespace-absolute `/royd` prefix before resolving task attributes against that controller root, preventing duplicated paths. Netd attaches Android's network BPF programs to the delegated root rather than rejecting the non-standard cgroup path. Runtime assertions verify the memory-controller delegation, a non-zero Launcher `memory.low`, PID 1 and `system_server` membership, and a running netd. They also reject duplicated cgroup roots, launch the WebView shell and require `system_server` to remain alive, covering the isolated-process group path used by WebView and other app zygotes.

On Android 15 containers, init retains the OCI stdout and stderr descriptors while still attaching stdin to `/dev/null`. Under the explicit container-without-SELinux gate, its normal logging setup selects AOSP's stderr logger rather than the host kernel logger. Retaining the descriptors alone is insufficient: restart tracing confirmed that the init host-power skip marker went to `/dev/kmsg`, not Docker logs. Qualification requires the stderr-mode marker. After rebuilding, also require the bounded power-write skip marker during a disposable zygote restart and retain a restricted native init/SystemSuspend syscall trace to check that the four host power controls remain untouched. Other Android environments retain kernel logging; severity selection, fatal reboot setup and the aborter remain unchanged. Repository-owned startup diagnostics, the boot watchdog and the `logcat` forwarding service write through PID 1, so `docker logs` does not depend on ADB or a host-side logging supervisor.

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
