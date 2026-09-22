# Development handoff notes

## Task 053 complete

Problem addressed: real Android 15 runtime evidence after task 052 showed that royd's private Binder devices and the SELinux-disabled `servicemanager` access gate were both active, but Binder transactions to the context manager still failed. `servicemanager` registered itself with `FLAT_BINDER_FLAG_TXN_SECURITY_CTX` and separately requested sender SIDs, so the Binder driver attempted to obtain SELinux security contexts even though the host kernel had SELinux disabled. `vold` could not register `VoldNativeService`, exited, and its `reboot_on_failure` policy shut Android down.

Important evidence discovered:

- Task 052 is externally validated for its intended blockers. The built and packaged image contained the patched `servicemanager`, `/dev/royd-binderfs`, and Binder node permission change. Runtime logs showed `servicemanager` advanced past Binder open and its previous `selinux_status_open(true)` abort.
- `apexd-bootstrap` still completed successfully in the task-052 image despite device-mapper warnings, so those warnings were not the shutdown trigger in this run.
- Exact `android-15.0.0_r36` source shows `ProcessState::becomeContextManager()` unconditionally sets `FLAT_BINDER_FLAG_TXN_SECURITY_CTX`, while `servicemanager/main.cpp` independently calls `manager->setRequestingSid(true)`.
- With kernel SELinux disabled, Binder sender-security-context delivery cannot provide the requested context. The first causal downstream failure was `vold` failing to register its native service, followed by `reboot,vold-failed`.
- Cgroup/task-profile warnings remain observable but are still not the first evidenced blocker and are not changed in task 053.

Files/interfaces changed:

- `android/patches/android-15.0.0_r36/0003-servicemanager-disable-binder-security-context-without-selinux.patch`: expose task 052's already-computed `Access::usesSelinux()` state to `servicemanager`, disable both SID requesting and Binder context-manager transaction security-context requests only when that state is false, and preserve normal Android behaviour otherwise.
- `frameworks/native/libs/binder/ProcessState` is patched by task 053 with an ABI-preserving bool overload. The existing zero-argument `becomeContextManager()` remains and delegates to the new overload with `true`, so existing callers retain the upstream security-context request by default.
- `android/scripts/android15-binder-security-context-test.sh`, `android/scripts/sync-contract-test.sh`, and `scripts/ci.sh`: cover the new gate, preserve the old libbinder API/default, verify exact Android-15-shaped patch application, and keep append-only patch-set extension working.
- `AGENTS.md`, `docs/security.md`, and these notes document the container-only Binder security-context rule.

Validation actually performed:

- The focused Android 15 Binder security-context, servicemanager, and sync/patch-application regressions passed.
- The sync regression applies all three Android 15 patches in order to Android-15-shaped fixtures and verifies the zero-argument libbinder API remains present with default security-context behaviour.
- Full `make ci` passed and printed `royd lightweight CI passed`. Static tests are not evidence that the new `frameworks/native` patch compiles in AOSP or that Android completes boot.
- Roadmap remains unchanged. No checkbox closes in task 053 because the new Android patch still requires a real incremental build and runtime validation.

External validation still required:

- Apply task 053 to the existing Android 15 source tree. The append-only patch helper should recognise tasks 051 and 052 as the already-applied prefix and apply only patch `0003`.
- Run an incremental Android 15 x86_64 standard/graphical/software build, package and import the image, then rerun the privileged smoke test.
- Confirm `servicemanager` remains running, sets `servicemanager.ready=true`, Binder no longer reports sender security-context transaction failures, and `vold` no longer exits while registering `VoldNativeService`.
- Treat the first later fatal blocker as new evidence. Do not infer that cgroups, zygote, graphics, ADB or boot completion are fixed until separately observed.

Unresolved failures or questions:

- The task-053 `frameworks/native` patch has exact-source-shape and patch-application regression coverage but has not yet compiled on the real AOSP tree.
- The runtime has not yet demonstrated stable `vold`, surviving zygotes, SurfaceFlinger startup or `sys.boot_completed=1`.
- Device-mapper and cgroup/task-profile warnings remain visible. Neither was the first shutdown trigger in the task-052 validation run, so neither is changed here.

Recommended next task: validate task 053 on the existing rented host with an incremental Android build and privileged runtime smoke test. If the image reaches a new boot failure, task 054 should address only that first evidenced blocker.

## Task 052 complete

Problem addressed: real Android 15 runtime evidence after task 051 showed that royd allocated Binder devices successfully during `early-init`, but Android later mounted its own binderfs instance over `/dev/binderfs`. The conventional `/dev/binder`, `/dev/hwbinder`, and `/dev/vndbinder` symlinks then pointed at missing targets. A live diagnostic proved that allocating into the later visible binderfs created working devices, and a second live override proved that keeping royd's private instance at `/dev/royd-binderfs` preserved working Binder devices across Android init. `servicemanager` then advanced past Binder open and exposed the next blocker: unconditional SELinux status initialisation on a kernel with SELinux disabled.

Important evidence discovered:

- Task 051 is externally validated for its intended blocker. `apexd-bootstrap` mounted and activated the bootstrap APEX packages and exited successfully, so the previous `Could not get process context` shutdown path is cleared.
- Before task 052, Android mounted a second binderfs instance at `/dev/binderfs`. royd's early allocations disappeared behind that mount while the conventional symlinks remained, leaving dangling Binder paths.
- Manually allocating `binder`, `hwbinder`, and `vndbinder` into the visible binderfs produced working character devices. The default dynamic-node mode was `0600`, and a later `servicemanager` restart failed with `Permission denied`, proving that royd must set Android-compatible permissions explicitly.
- A live override using `/dev/royd-binderfs` plus mode `0666` produced working `/dev/binder`, `/dev/hwbinder`, and `/dev/vndbinder` character devices while Android's own `/dev/binderfs` mount remained separate. `servicemanager` then opened Binder successfully and failed later at `selinux_status_open(true)`.
- Exact `android-15.0.0_r36` `frameworks/native` source at commit `cdca1e2000347ce2f2b25ab5d0f2dffa81f30e01` shows `Access::Access()` unconditionally opens SELinux status and gets its process context, while service-manager access paths call SELinux lookup and access-check APIs.
- Android init service launch inherits the PID 1 environment and adds service-specific variables without clearing it, so the existing explicit `ROYD_CONTAINER=1` marker is available to Android services.
- Cgroup/task-profile warnings remain observable, but they were not the first new blocker and are not changed in task 052.

Files/interfaces changed:

- `android/royd/vendor/royd/bin/royd-binder-setup`: mount royd's private Binder instance at `/dev/royd-binderfs` and set allocated Binder nodes to `0666` before exposing the conventional paths.
- Binder diagnostics, runtime assertions, identity helpers, qualification fixtures and documentation now use the royd-owned private binderfs mountpoint while still reporting Android's own `/dev/binderfs` where useful.
- `android/patches/android-15.0.0_r36/0002-servicemanager-support-royd-container-selinux-disabled.patch`: only when `ROYD_CONTAINER=1` and kernel SELinux is disabled, skip `servicemanager` SELinux status/context initialisation and allow service-manager operations without SELinux policy lookups. Normal Android behaviour is unchanged otherwise.
- `android/scripts/apply-patches.sh`: permit append-only extension of an already-applied local patch set when the existing marker matches an exact prefix digest. Changed, reordered, or removed prior patches still require a fresh source tree.
- `android/scripts/android15-servicemanager-container-test.sh`, `runtime/scripts/binder-contract-test.sh`, `android/scripts/sync-contract-test.sh`, and `scripts/ci.sh`: cover the new Binder mountpoint, node permissions, SELinux-disabled service-manager gate, clean patch application and append-only patch-set extension.
- `AGENTS.md`, `runtime/README.md`, `docs/architecture.md`, `docs/hardware-contract.md`, `docs/runtime.md`, `docs/validation.md`, and these notes.

Validation actually performed:

- Focused shell syntax, Binder contract, Android 15 container-init, Android 15 servicemanager and sync/patch-application regressions passed.
- The sync regression applies both Android 15 patches to Android-15-shaped fixtures, verifies the normal SELinux code remains present behind the new gate, then appends and applies a new patch without requiring a fresh source tree.
- Full `make ci` must pass before this task is handed off. Static tests are not evidence that the new `frameworks/native` patch compiles in AOSP or that Android completes boot.
- Roadmap remains unchanged. No checkbox closes in task 052 because the new Android patch still needs a real incremental build and runtime validation.

External validation still required:

- Apply task 052 to the existing Android 15 source tree. The updated patch helper should recognise the already-applied task-051 patch as an exact prefix and apply only the new task-052 patch.
- Run an incremental Android 15 x86_64 standard/graphical/software build, package and import the image, then rerun the privileged smoke test.
- Confirm `/dev/royd-binderfs/{binder,hwbinder,vndbinder}` are `0666` character devices, conventional Binder paths resolve to them, and `servicemanager` no longer aborts at either Binder open or `selinux_status_open(true)`.
- Treat the first later fatal blocker as new evidence. Do not infer that cgroups, `vold`, zygote, graphics, ADB or boot completion are fixed until separately observed.

Unresolved failures or questions:

- The new Android 15 `frameworks/native` patch has exact-source-shape and patch-application regression coverage but has not yet compiled on the real AOSP tree.
- The runtime has not yet demonstrated a stable `servicemanager.ready`, successful `vold` startup, surviving zygotes, SurfaceFlinger startup or `sys.boot_completed=1`.
- Cgroup/task-profile configuration remains noisy and may become a later task only if it is the first evidenced blocker after task 052.

Recommended next task: validate task 052 on the existing rented host with an incremental Android build and privileged runtime smoke test. If the image reaches a new boot failure, task 053 should address only that first evidenced blocker.

## Task 051 external-validation correction

Real `android-15.0.0_r36` validation found that the repository-owned `system/core/init` patch did not apply to the pinned source tree. The patch had been authored against a different init source shape: `Service::SetProcessAttributesAndCaps()` lacked the Android 15 FIFO parameter in the fixture, and the subcontext fixture used the older `InitializeSubcontexts()` vector API instead of Android 15's `InitializeSubcontext()` single-subcontext API. No patched init binary was therefore built, so the repeated `Could not get process context` and vendor-init `setexeccon` failures were still stock-AOSP behaviour rather than evidence of a new blocker.

The task-051 patch is now rebased onto the exact `android-15.0.0_r36` init call sites while preserving the original narrow gate: only `ROYD_CONTAINER=1` with kernel SELinux disabled bypasses service process-context selection/application and vendor-init subcontext creation. The sync fixture and container-init contract test now reflect the pinned Android 15 source shape. Real AOSP compile and runtime validation are still required before task 051 can be considered externally validated.

## Task 051 complete

Problem addressed: real Android 15 runtime validation proved that royd can reach Android second-stage init, but stock first-stage init is incompatible with an OCI environment that already provides `/sys`, and second-stage startup then failed because `/dev/socket` was absent and SELinux-labelled service/subcontext startup was attempted on a host kernel with SELinux disabled. Task 051 formalises the second-stage container entry contract and adds a narrowly gated Android 15 init adaptation for the SELinux-disabled royd container case.

Important evidence discovered:

- Task 050 external validation wrote `/royd-runtime.conf` successfully and Android first-stage init then aborted after `mount("sysfs", "/sys", ...)` returned `EBUSY` and `selinuxfs` could not be mounted. This proves the royd bootstrap handed PID 1 to Android init.
- A direct `exec /init second_stage` diagnostic advanced through product-property loading and restorecon with SELinux disabled, then failed because `/dev/socket/property_service_for_system` could not be created.
- Adding a private `/dev/socket` tmpfs allowed Android to create both property-service sockets, set up mount namespaces, parse stock init configuration and `/vendor/etc/init/init.royd.rc`, and enter `early-init`.
- The next fatal blocker was `apexd-bootstrap`: service launch failed with `Could not get process context`, while vendor-init subcontexts repeatedly failed `setexeccon(...): Invalid argument`. Cgroup/task-profile warnings were also observed but were not the shutdown trigger and are not changed in task 051.
- Exact AOSP init source evidence shows service startup computes SELinux process contexts before launch and vendor-init subcontexts call `setexeccon`; Android init also has an explicit `second_stage` dispatch path. The repository patch therefore remains limited to the explicit royd-container plus SELinux-disabled condition.

Files/interfaces changed:

- `runtime/rootfs/royd-entrypoint`: export the explicit `ROYD_CONTAINER=1` marker and hand off to `/init second_stage`.
- `runtime/scripts/container-args.sh`: define the private `/dev/socket` tmpfs runtime argument.
- Runtime smoke, qualification, memory, multi-instance and Binder-isolation launchers, Compose baseline files, and the optional Go CLI now include the `/dev/socket` tmpfs contract.
- `android/patches/android-15.0.0_r36/0001-init-support-royd-container-selinux-disabled.patch`: when and only when `ROYD_CONTAINER=1` and kernel SELinux is disabled, skip service SELinux process-context selection/application and vendor-init subcontext creation. Normal Android behaviour is unchanged otherwise.
- `android/scripts/android15-container-init-test.sh` and `android/scripts/sync-contract-test.sh`: validate the new init patch contract and repository patch application.
- `README.md`, `docs/runtime.md`, `scripts/ci.sh`, CLI tests, and these notes.

Validation actually performed:

- Focused shell syntax, Android 15 container-init, sync/patch-application, entrypoint, image, security, repository/runtime and Go CLI tests passed.
- Full `make ci` passed end to end in a detached rerun and printed `royd lightweight CI passed`. A foreground invocation had previously been terminated by the execution wrapper during `config-check-test.sh` without an assertion failure.
- Static tests are not evidence that the Android 15 `system/core/init` patch compiles in AOSP or that the container boots.

External validation still required:

- Subsequent real-host validation rebuilt and imported the task-051 image. `apexd-bootstrap` mounted and activated the bootstrap APEX packages and exited successfully, clearing the task-051 SELinux process-context blocker.

Unresolved failures or questions:

- The Android 15 init patch compiled in the real `android-15.0.0_r36` tree and cleared its intended runtime blocker.
- Cgroup setup currently reports missing `/etc/cgroups.json`, `/etc/task_profiles.json`, and uninitialised processgroup controllers during the second-stage diagnostic. Those warnings were not the task-051 fatal blocker and remain later evidence if they persist after `apexd-bootstrap` starts.
- Successful APEX activation, Binder setup, framework boot, log forwarding, ADB, SurfaceFlinger and graphics remain unproven.

Recommended next task: rebuild Android 15 with the task-051 `system/core/init` patch and rerun packaging/import/smoke validation. Task 052 should address only the first new evidenced failure.

Exact commands on the existing real AOSP build host:

```sh
cd /root/royd
ROYD_ANDROID_VERSION=15 ./android/scripts/apply-patches.sh .work/android-src-15
./build.sh \
  --android 15 \
  --arch x86_64 \
  --profile standard \
  --hal-profile graphical \
  --graphics software \
  --jobs "$(nproc)" \
  --skip-sync \
  --incremental
```

Expected evidence to return: the complete first failure from patch application, compile/link, packaging, import, or smoke boot. Success evidence should show the local Android 15 init patch applying, a successful Android build and package/import, then kernel/init logs in which `init second stage started!`, property-service socket creation succeeds, and `apexd-bootstrap` no longer fails with `Could not get process context`. Do not treat later cgroup, APEX, Binder, graphics, or framework failures as fixed until separately evidenced.

## Task 050 complete

Problem addressed: task 049 let the Android 15 bootstrap shell parse release metadata safely, but the real container then exited while writing `/royd-runtime.conf`. Android's pre-APEX shell resolved `printf` to `/bin/printf`, which was not executable before the normal Runtime APEX linker environment existed. Task 050 removes `printf` and keeps the complete pre-init entrypoint path on shell built-ins until `exec /init`.

Important evidence discovered:

- External task-049 validation started the container through the bootstrap linker and reached `/royd-entrypoint` beyond release-metadata parsing. The persistent reproduction exited with code 126, was not OOM-killed, and logged `/royd-entrypoint[68]: /bin/printf: No such file or directory`.
- The preceding warning about missing `/linkerconfig/ld.config.txt` again did not stop the bootstrap shell. The observed fatal error was the external `printf` utility invocation.
- Directly selecting `/system/bin/sh` still bypasses the bootstrap linker and remains an invalid pre-APEX diagnostic path.
- The successful pre-init path now uses shell syntax, parameter expansion, `read`, `case`, `[`, `echo`, `umask`, and finally `exec /init`. No conclusion is drawn yet about whether Android init survives first-stage startup or reaches second stage.

Files/interfaces changed:

- `runtime/rootfs/royd-entrypoint`: replace every pre-init `printf` invocation, including validation errors and runtime-config generation, with shell-builtin `echo`.
- `runtime/scripts/entrypoint-contract-test.sh`: exercise the successful pre-init path with `PATH` pointing at a non-existent directory and explicitly reject `printf` in the entrypoint so host-shell builtin differences cannot hide the Android failure.
- `docs/development-notes.md`.

Validation actually performed:

- `sh -n runtime/rootfs/royd-entrypoint` and `sh -n runtime/scripts/entrypoint-contract-test.sh` passed.
- `runtime/scripts/entrypoint-contract-test.sh`, `runtime/scripts/image-contract-test.sh`, `android/scripts/package-contract-test.sh`, `android/scripts/version-test.sh`, `android/scripts/android15-build-readiness-test.sh`, `scripts/check-runtime.sh`, and `scripts/check-repo.sh` passed.
- A foreground `make ci` invocation was terminated by the execution wrapper while entering `config-check-test.sh`, with no assertion failure before termination. A single detached rerun then completed with exit status 0 and printed `royd lightweight CI passed`, including the task-050 entrypoint regression, Android package and image contracts, runtime qualification contracts, reference-host bundle test, and `go test ./...`.
- Roadmap remains 63 checked and 24 open. No checkbox closes in task 050 because the changed entrypoint still requires real-host execution and Android `/init` has not yet been shown to stay running.

External validation still required:

- Repackage Android 15 x86_64 using the existing successful AOSP output so the updated `/royd-entrypoint` is embedded in the rootfs archive. AOSP rebuild and Repo sync are not required.
- Re-import the updated archive and rerun the runtime smoke test.
- Confirm the previous `/bin/printf: No such file or directory` failure is gone. If `/init` starts and a later failure appears, preserve the first new init/runtime evidence rather than changing unrelated Binder, SELinux, graphics, or VINTF code.

Unresolved failures or questions:

- It is not yet externally proven that `/royd-entrypoint` successfully writes `/royd-runtime.conf`, `exec`s `/init`, or leaves Android init as PID 1.
- The pre-init linker configuration warning remains observable but has twice been followed by successful shell execution, so no workaround is justified from current evidence.
- Successful Android boot, log forwarding, ADB, Binder isolation, SurfaceFlinger, software graphics, memory qualification, and clean architecture build gates remain open.

Recommended next task: validate task 050 on the existing rented host. If `/init` is reached and a new failure appears, task 051 should address only that first evidenced init/runtime blocker. If the smoke test succeeds, task 051 should collect the first successful runtime qualification evidence instead of introducing unrelated implementation.

Exact commands on the existing rented host:

```sh
cd /root/royd
git pull

env \
  ROYD_ANDROID_VERSION=15 \
  ROYD_ANDROID_PROFILE=standard \
  ROYD_HAL_PROFILE=graphical \
  ROYD_GRAPHICS_BACKEND=software \
  ROYD_BUILDER_TTY=never \
  ./android/scripts/builder.sh android/scripts/package.sh x86_64 standard

env \
  ROYD_ANDROID_VERSION=15 \
  ROYD_ANDROID_PROFILE=standard \
  ROYD_HAL_PROFILE=graphical \
  ROYD_GRAPHICS_BACKEND=software \
  ./runtime/scripts/import.sh x86_64 standard

ROYD_ANDROID_VERSION=15 \
ROYD_ANDROID_PROFILE=standard \
ROYD_HAL_PROFILE=graphical \
ROYD_GRAPHICS_BACKEND=software \
make runtime-smoke-test
```

Expected evidence to return: complete package, import, and smoke-test output. Packaging should report both runtime artefacts ready, import should report `Image contract passed` and `Runtime image is ready`, and the previous `/bin/printf: No such file or directory` error must be absent. Runtime success is `Single-instance runtime smoke test passed`. On failure, preserve a debug container and return its `docker inspect` state and complete `docker logs`. Do not rebuild AOSP unless a later failure specifically requires it.

## Task 049 complete

Problem addressed: task 048 made the Android 15 bootstrap shell executable before Runtime APEX activation, but the container then exited inside `/royd-entrypoint`. The entrypoint sourced `/royd-release` as shell code even though the repository generates that file as plain metadata and values such as `ANDROID_REQUIRED_PARTITIONS=system vendor system_ext product` contain unquoted spaces. Task 049 stops executing release metadata and parses only the required `ROYD_HAL_PROFILE` key with shell built-ins.

Important evidence discovered:

- External task-048 validation started the container through `/system/bin/bootstrap/linker64`, `/system/bin/sh`, and `/royd-entrypoint`. The container exited with code 127, was not OOM-killed, and logged `/royd-entrypoint: /royd-release[11]: vendor: inaccessible or not found`.
- The preceding bootstrap-linker warning about missing `/linkerconfig/ld.config.txt` did not stop execution. The shell continued into `/royd-entrypoint`, so task 048's bootstrap path is externally proven to execute on the Android 15 image.
- `android/scripts/package.sh` intentionally emits plain `KEY=value` release metadata. `ANDROID_REQUIRED_PARTITIONS` expands to a space-separated list, so sourcing the file causes the shell to treat `vendor` as a command. No conclusion is drawn yet about later Android init, Binder, SELinux, graphics, APEX activation, or framework startup.
- Directly selecting `/system/bin/sh` still bypasses the task-048 bootstrap linker and is not a valid diagnostic path before Runtime APEX activation.

Files/interfaces changed:

- `runtime/rootfs/royd-entrypoint`: parse `ROYD_HAL_PROFILE` from `/royd-release` as data instead of sourcing the metadata file.
- `runtime/scripts/entrypoint-contract-test.sh`: use production-like release metadata with space-separated partitions and prove unrelated shell-active metadata is not executed.
- `docs/development-notes.md`.

Validation actually performed:

- `sh -n runtime/rootfs/royd-entrypoint runtime/scripts/entrypoint-contract-test.sh` passed.
- `runtime/scripts/entrypoint-contract-test.sh`, `runtime/scripts/image-contract-test.sh`, `android/scripts/package-contract-test.sh`, `android/scripts/version-test.sh`, `scripts/check-runtime.sh`, and `scripts/check-repo.sh` passed.
- Full `make ci` passed end to end and printed `royd lightweight CI passed`, including the task-049 entrypoint regression, Android package and image contracts, runtime qualification contracts, reference-host bundle test, and `go test ./...`.
- Repository policy scans passed: no em dashes were found and no prohibited prior-art name references were found outside `docs/acknowledgements.md`.
- The generated patch passed `git apply --check`, applied cleanly to a fresh copy of the exact task-048 tree, and the patched tree matched the finished tree byte-for-byte and file-mode-for-file-mode. The finished ZIP round-trip matched by the same comparison.
- Roadmap remains 63 checked and 24 open. No checkbox closes in task 049 because `/init` and Android boot still require real-host validation after repackaging the changed entrypoint.

External validation still required:

- Repackage Android 15 x86_64 using the existing successful AOSP output so the updated `/royd-entrypoint` is embedded in the rootfs archive. AOSP rebuild and Repo sync are not required.
- Re-import the updated archive and rerun the runtime smoke test.
- Confirm the previous `/royd-release[11]: vendor: inaccessible or not found` failure is gone. If Android reaches a later failure, preserve the first new container/init evidence rather than changing unrelated subsystems.

Unresolved failures or questions:

- It is not yet externally proven that the corrected entrypoint writes `/royd-runtime.conf`, successfully `exec`s `/init`, or leaves Android init as PID 1.
- The bootstrap linker still warns that `/linkerconfig/ld.config.txt` is absent before init. The warning was non-fatal for the shell entrypoint, and no workaround is justified without evidence that it blocks a later stage.
- Successful Android boot, log forwarding, ADB, Binder isolation, SurfaceFlinger, software graphics, memory qualification, and clean architecture build gates remain open.

Recommended next task: validate task 049 on the existing rented host. If `/init` is reached and a new failure appears, task 050 should address only that first evidenced init/runtime blocker. If the smoke test succeeds, task 050 should collect the first successful runtime qualification evidence rather than introduce unrelated implementation.

Exact commands on the existing rented host:

```sh
cd /root/royd
git pull

env \
  ROYD_ANDROID_VERSION=15 \
  ROYD_ANDROID_PROFILE=standard \
  ROYD_HAL_PROFILE=graphical \
  ROYD_GRAPHICS_BACKEND=software \
  ROYD_BUILDER_TTY=never \
  ./android/scripts/builder.sh android/scripts/package.sh x86_64 standard

env \
  ROYD_ANDROID_VERSION=15 \
  ROYD_ANDROID_PROFILE=standard \
  ROYD_HAL_PROFILE=graphical \
  ROYD_GRAPHICS_BACKEND=software \
  ./runtime/scripts/import.sh x86_64 standard

ROYD_ANDROID_VERSION=15 \
ROYD_ANDROID_PROFILE=standard \
ROYD_HAL_PROFILE=graphical \
ROYD_GRAPHICS_BACKEND=software \
make runtime-smoke-test
```

Expected evidence to return: complete package, import, and smoke-test output. Packaging should report both runtime artefacts ready, import should report `Image contract passed` and `Runtime image is ready`, and the previous `vendor: inaccessible or not found` error must be absent. Runtime success is `Single-instance runtime smoke test passed`. On failure, return the first new error plus `docker inspect` state and `docker logs` from a preserved reproduction. Do not rebuild AOSP unless a later failure specifically requires it.

## Task 048 complete

Problem addressed: after task 047 corrected Android 15 rootfs assembly, the imported image still exited before the royd shell entrypoint could run. Docker reported `exec /royd-entrypoint: no such file or directory`, and directly selecting `/system/bin/sh` produced the same error. The real Android 15 image showed that normal `sh` depends on the Runtime APEX linker, which is not available before Android init activates APEXes. Task 048 makes the OCI bootstrap use Android's existing bootstrap linker for system-root images before running the royd shell script.

Important evidence discovered:

- The task-047 smoke test passed the repository security check, then the container stopped before Android boot completed. A persistent reproduction exited with code 255, was not OOM-killed, and Docker logged `exec /royd-entrypoint: no such file or directory`. Direct `/system/bin/sh` execution returned the same error.
- Mounting the exact Android 15 `system.img` showed a real `/system/bin/sh`, a real `/system/bin/init`, `/system/bin/linker64 -> /apex/com.android.runtime/bin/linker64`, and a real `/system/bin/bootstrap/linker64`. `readelf` showed `sh` requests `/system/bin/linker64`, while `init` requests `/system/bin/bootstrap/linker64`. The image also contains `com.android.runtime.apex` and `com.android.art.capex` payloads.
- This evidence is consistent with the normal shell's ELF interpreter being unavailable before Runtime APEX activation. It does not prove any later Android init, APEX, SELinux, Binder, graphics, or framework behaviour.
- Upstream Bionic linker source documents direct invocation as `linker program [arguments...]`. It also documents that the bootstrap linker prefers `/system/${LIB}/bootstrap` ahead of the normal system library path. Task 048 uses that upstream bootstrap mechanism rather than copying or rewriting linker/APEX contents.
- Android 10 through 17 use the system-root path in repository metadata, so their OCI entrypoint is now `/system/bin/bootstrap/linker64`, `/system/bin/sh`, `/royd-entrypoint`. Android 8.0 through 9 retain direct `/royd-entrypoint`. Only Android 15 has external evidence for the linker layout so far.

Files/interfaces changed:

- `runtime/scripts/image-entrypoint.sh`: new version-family entrypoint contract for ramdisk-root and system-root images.
- `runtime/scripts/import.sh`: inject the version-aware OCI entrypoint instead of always executing `/royd-entrypoint` directly.
- `runtime/scripts/image-inspect.sh`: verify the expected version-aware entrypoint metadata.
- `runtime/scripts/image-contract-test.sh` and `scripts/check-runtime.sh`: focused regressions for the bootstrap entrypoint and legacy direct path.
- `docs/runtime.md`, `docs/architecture.md`, `runtime/README.md`: concise bootstrap-path documentation.
- `docs/development-notes.md`.

Validation actually performed:

- Shell syntax checks passed for the changed shell scripts.
- `android/scripts/version-test.sh`, `android/scripts/package-contract-test.sh`, `runtime/scripts/image-contract-test.sh`, `runtime/scripts/entrypoint-contract-test.sh`, `scripts/check-runtime.sh`, and `scripts/check-repo.sh` passed.
- Full `make ci` passed end to end in a persistent run, including resolved Android configuration, package contracts, runtime qualification contracts, reference-host bundle tests, and `go test ./...`.
- The first foreground `make ci` invocation was terminated by the execution wrapper during `config-check-test.sh`; the persistent rerun completed with exit status 0. Only the completed rerun is recorded as the task validation result.
- Repository policy scans passed: no em dashes were found and no prohibited prior-art name references were found outside `docs/acknowledgements.md`.
- The generated patch passed `git apply --check`, applied cleanly to a fresh copy of the exact task-047 tree, and the patched tree matched the finished tree byte-for-byte and file-mode-for-file-mode. The finished ZIP round-trip matched by the same comparison.
- Roadmap remains 63 checked and 24 open. No checkbox closes in task 048 because the new bootstrap entrypoint has not yet executed on the real host and Android has not booted.

External validation still required:

- Re-import the existing task-047 Android 15 x86_64 packaged archive. Repackaging and rebuilding AOSP are not required because task 048 changes only Docker image metadata and host-side contract tooling.
- Confirm the imported image entrypoint is `["/system/bin/bootstrap/linker64","/system/bin/sh","/royd-entrypoint"]` and rerun the runtime smoke test.
- If the container reaches `/init` and fails later, treat that first new init/runtime error as new evidence rather than changing unrelated Binder, SELinux, graphics, or VINTF code.

Unresolved failures or questions:

- The bootstrap-linker invocation is supported by upstream Bionic source and by the real Android 15 filesystem layout, but it still needs direct execution evidence in the imported royd image.
- It is not yet externally proven that `/royd-entrypoint` writes `/royd-runtime.conf` on Android 15 or that `/init` becomes PID 1.
- Android 10 through 14 and 16 through 17 share the system-root entrypoint contract statically but have no real bootstrap execution evidence.
- Clean Android build gates, successful boot, log forwarding, ADB, Binder isolation, SurfaceFlinger, and graphics qualification remain open.

Recommended next task: validate task 048 on the existing rented host. If the image reaches a new failure after the royd entrypoint starts or after `/init` takes PID 1, task 049 should address only that first evidenced blocker. If the smoke test succeeds, task 049 should collect the first successful runtime qualification evidence rather than starting unrelated implementation.

Exact commands on the existing rented host:

```sh
cd /root/royd
git pull

env \
  ROYD_ANDROID_VERSION=15 \
  ROYD_ANDROID_PROFILE=standard \
  ROYD_HAL_PROFILE=graphical \
  ROYD_GRAPHICS_BACKEND=software \
  ./runtime/scripts/import.sh x86_64 standard

docker image inspect --format '{{json .Config.Entrypoint}}' royd:dev

ROYD_ANDROID_VERSION=15 \
ROYD_ANDROID_PROFILE=standard \
ROYD_HAL_PROFILE=graphical \
ROYD_GRAPHICS_BACKEND=software \
make runtime-smoke-test
```

Expected evidence to return: complete import output, the Docker entrypoint inspection, and complete smoke-test output. The entrypoint inspection should print `["/system/bin/bootstrap/linker64","/system/bin/sh","/royd-entrypoint"]`. Import should still report `Image contract passed` and `Runtime image is ready`. Runtime success is `Single-instance runtime smoke test passed`. On failure, return the first new container error and `docker logs` from a preserved reproduction. Do not rebuild or repackage Android for this validation.

## Task 047 complete

Problem addressed: the first imported Android 15 image could not execute `/royd-entrypoint` or `/system/bin/sh` because the OCI packager nested Android 15 `system.img` under `/system`. The built `system.img` is itself the Android root filesystem, so its root-level `bin -> /system/bin` symlink became the self-referential `/system/bin -> /system/bin` inside the container. Task 047 corrects rootfs assembly and permanently carries the separately evidenced Docker import label quoting fix needed to re-import the repaired archive.

Important evidence discovered:

- External task-046 validation succeeded. The existing Android 15 x86_64 build repackaged successfully and produced both `.work/runtime/android-15/royd-x86_64-standard-graphical.manifest` and `.tar` without the earlier cleanup errors.
- The first `runtime/scripts/import.sh` attempt failed in Docker with `Syntax error - can't find = in "runtime"` because the OCI description label contained spaces without quotes. Quoting the label value on the rented host allowed import to complete, `Image contract passed`, and both the canonical tag and `royd:dev` referenced image ID `d0fd9c6acbff`.
- `make runtime-host-check` returned zero errors on the rented host. The subsequent smoke test started the container and passed its security check, but the container stopped before Android boot completed.
- A persistent reproduction exited with code 255, was not OOM-killed, and `docker logs` reported `exec /royd-entrypoint: too many levels of symbolic links`. Attempting `/system/bin/sh` directly failed with the same error before Android init ran.
- Mounting the exact built Android 15 `system.img` showed `/bin -> /system/bin`, `/init -> /system/bin/init`, a real `/system/bin` directory, and a real `/system/bin/sh`. This directly proves that nesting that image at `/system` creates the observed loop.
- AOSP init documentation states that from Android Q, `system.img` contains the root output and is mounted at `/` by the end of first-stage init. The repository now records `ANDROID_ROOTFS_SOURCE=system` for Android 10 through 17 and retains `ramdisk` for Android 8.0 through 9. Only Android 15 has real external packaging evidence so far.

Files/interfaces changed:

- `android/versions/8.0.env` through `android/versions/17.env`: add explicit `ANDROID_ROOTFS_SOURCE` metadata.
- `android/scripts/package.sh`: use `system.img` as OCI `/` for system-root versions, skip re-adding the root partition, and retain the legacy ramdisk path where declared.
- `android/scripts/package-contract-test.sh`: cover Android 15 system-root layout, partition merge points, absent optional `odm`, missing required partitions, Android 9 ramdisk assembly, and best-effort cleanup.
- `android/scripts/version-test.sh`: assert the rootfs source contract for every pinned version.
- `runtime/scripts/import.sh`: quote the OCI description label value accepted by Docker import.
- `runtime/scripts/image-contract-test.sh`: guard the import label quoting regression.
- `docs/runtime.md`, `docs/building.md`, and `runtime/README.md`: document version-aware rootfs assembly.
- `docs/development-notes.md`.

Validation actually performed:

- Shell syntax checks passed for the changed shell scripts.
- `version-test.sh`, `package-contract-test.sh`, `image-contract-test.sh`, `check-runtime.sh`, `check-repo.sh`, `contract-test.sh`, `config-check-test.sh`, `matrix-report-test.sh`, `build-matrix-test.sh`, `build-helper-test.sh`, and `android15-build-readiness-test.sh` passed.
- Full `make ci` passed end to end, including the package contract, runtime contract tests, qualification contract tests, reference-host bundle test, and `go test ./...`.
- Roadmap remains 63 checked and 24 open. No checkbox closes in task 047 because the corrected archive has not yet been repackaged, imported, or booted on the real host.

External validation still required:

- Repackage Android 15 x86_64 from the existing successful AOSP output. A full Android rebuild is not required for this task.
- Re-import the new archive without the rented-host-only `import.sh` edit, then rerun the runtime smoke test.
- If boot proceeds further but fails, treat the first new Android init/runtime failure as new evidence. Do not infer graphics, Binder, SELinux, or framework success from passing the previous pre-exec failure.

Unresolved failures or questions:

- The corrected Android 15 rootfs layout has static repository coverage but no real-host execution evidence yet.
- Android 10 through 14 and 16 through 17 use the upstream system-root contract in repository metadata, but none of those tuples has real package or boot validation yet.
- The previous Android 15 build was incremental. Clean x86_64 and arm64 build gates remain open.
- No real Android boot has yet established that `/init` reaches second stage, that log forwarding starts, or that SurfaceFlinger and the modern graphics services initialise successfully.

Recommended next task: validate task 047 on the existing rented host. If the corrected image reaches a new boot failure, task 048 should address only that first evidenced runtime blocker. If the smoke test passes, task 048 should record and inspect the first successful runtime qualification evidence rather than starting unrelated implementation.

Exact commands on the existing rented host, after the task-047 commit is available:

```sh
cd /root/royd
# The host currently has the temporary task-047 import-label edit already applied.
git restore runtime/scripts/import.sh
git pull

env \
  ROYD_ANDROID_VERSION=15 \
  ROYD_ANDROID_PROFILE=standard \
  ROYD_HAL_PROFILE=graphical \
  ROYD_GRAPHICS_BACKEND=software \
  ROYD_BUILDER_TTY=never \
  ./android/scripts/builder.sh android/scripts/package.sh x86_64 standard

env \
  ROYD_ANDROID_VERSION=15 \
  ROYD_ANDROID_PROFILE=standard \
  ROYD_HAL_PROFILE=graphical \
  ROYD_GRAPHICS_BACKEND=software \
  ./runtime/scripts/import.sh x86_64 standard

ROYD_ANDROID_VERSION=15 \
ROYD_ANDROID_PROFILE=standard \
ROYD_HAL_PROFILE=graphical \
ROYD_GRAPHICS_BACKEND=software \
make runtime-smoke-test
```

Expected evidence to return: complete output from all three stages. Packaging should say `Creating OCI root filesystem archive from Android system image` and produce the manifest and tar. Import should print `Development alias is ready`, `Image contract passed`, and `Runtime image is ready` without a Docker label syntax error. Runtime success is `Single-instance runtime smoke test passed`. On failure, return the complete smoke-test output and the first new error. Preserve the existing AOSP build output and do not start a clean rebuild for this validation.

## Task 046 complete

Problem addressed: the real Android 15 x86_64 software build completed successfully, then the OCI packaging stage exited before writing its manifest and the EXIT cleanup reported permission errors removing extracted `root/dev/console`, `root/dev/null`, and `root/dev/urandom`. The packaging path had two related shell defects: an absent optional partition could terminate `append_image` under `set -e`, and cleanup treated deletion of the privileged ramdisk extraction as mandatory even though that tree can contain root-owned device nodes.

Important evidence discovered:

- The returned external log reports `build completed successfully` for the Android 15 x86_64 standard, graphical, software tuple before packaging starts. This is real evidence that task 045's duplicate allocator init install rule no longer blocks this incremental build. It is not clean-build or runtime evidence.
- `package.sh` extracts the ramdisk with `sudo cpio` so Android ownership, modes, and device nodes are preserved. Its cleanup previously used unprivileged `rm -rf`, which can fail on the resulting root-owned `/dev` content. The supported builder itself is disposable because `builder.sh` launches Docker with `--rm`.
- `ANDROID_OPTIONAL_PARTITIONS` contains `odm` for Android 15. The former missing-image branch used `[ "$required" = yes ] && fail ...` followed by `return` under `set -e`. In the focused regression, an absent optional `odm.img` caused that branch to terminate packaging before the manifest. This is repository evidence of a defect, but the returned external log does not prove that `odm.img` was absent on the build host.
- The corrected branch uses an explicit `if` for required partitions and returns success for an absent optional partition. Cleanup now treats deletion of the builder-local temporary tree as best effort while still attempting normal unprivileged cleanup. No extra sudo permission was added.

Files/interfaces changed:

- `android/scripts/package.sh`
- `android/scripts/package-contract-test.sh`
- `scripts/ci.sh`
- `Makefile`
- `docs/development-notes.md`

Validation actually performed:

- The focused package contract test passed. It packages successfully with no `odm.img`, simulates a permission denial deleting the temporary ramdisk extraction, verifies that the denial is non-fatal and silent, verifies that no absent `odm` tree is added, and verifies that a missing required `vendor.img` still fails explicitly.
- `build-matrix-test.sh`, `build-helper-test.sh`, `check-runtime.sh`, `check-repo.sh`, shell syntax checks, and `git diff --check` passed.
- Literal `make ci` was attempted. No assertion failed before this execution environment terminated the combined run while entering `config-check-test.sh`. `config-check-test.sh` passed separately in 23.54 seconds. Every remaining command in `scripts/ci.sh` was then observed passing in direct runs, including the new package contract test, runtime qualification and reference-host tests, and `go test ./...`. This is not recorded as a successful literal `make ci` run.
- Roadmap remains 63 checked and 24 open. Task 046 closes no roadmap checkbox because the returned Android build was incremental, packaging still needs external confirmation, and no image has been imported or booted.

External validation still required:

- Rerun only the Android 15 x86_64 packaging stage against the existing successful build output. Confirm an absent optional partition, if any, is skipped without aborting and that cleanup no longer reports permission errors.
- Confirm the package writes both the root filesystem archive and sidecar manifest. Image import and runtime boot remain later gates.

Unresolved failures or questions:

- The returned external excerpt does not identify whether `odm.img` existed, so the optional-partition defect must not be recorded as the proven external trigger. The rerun will distinguish successful packaging from any separate underlying packaging failure that the old cleanup noise may have obscured.
- The successful Android build was incremental. A clean Android 15 build for both royd products remains required by the roadmap.
- The produced archive has not yet been imported into Docker or exercised by runtime qualification.

Recommended next task: rerun the package stage on the existing build host. Task 047 should use that result as evidence. If packaging succeeds, keep task 047 bounded to the next image-import or runtime-readiness failure rather than starting unrelated architecture work.

Exact external command on the existing build host:

```sh
cd /root/royd
env \
  ROYD_ANDROID_VERSION=15 \
  ROYD_ANDROID_PROFILE=standard \
  ROYD_HAL_PROFILE=graphical \
  ROYD_GRAPHICS_BACKEND=software \
  ROYD_BUILDER_TTY=never \
  ./android/scripts/builder.sh android/scripts/package.sh x86_64 standard
```

Expected evidence to return: the complete command output. Success must include both `Runtime manifest is ready:` and `Runtime root filesystem is ready:` and must not contain the previous `rm: cannot remove ... root/dev/...: Permission denied` lines. If it still fails, return the first genuine failure plus approximately 100 surrounding lines. Do not delete or regenerate the existing AOSP build output before this packaging-only check.

## Task 045 complete

Problem addressed: the real Android 15 x86_64 software build failed during Kati rule generation because `vendor/etc/init/allocator.rc` had two install commands. The repository-owned Android 15 allocator used the generic `allocator.rc` basename for its Soong `init_rc` file.

Important evidence discovered:

- The returned real-build log reached completion of legacy Make parsing, then `ckati` rejected duplicate commands for `out/target/product/royd_x86_64/vendor/etc/init/allocator.rc`. This is external build evidence, not a static prediction.
- royd's allocator Soong module installed `allocator/allocator.rc`, which maps its basename into the vendor init directory.
- Upstream AOSP minigbm also has an AIDL allocator init file named `allocator.rc`. This makes the generic basename unsafe in the Android build graph, although the returned log excerpt does not identify the second rule's owning module.
- The allocator init file is now named `android.hardware.graphics.allocator-service.royd.rc`. The allocator binary stem, Binder service instance, VINTF contract, mapper, composer, and product selection are unchanged.

Files/interfaces changed:

- `android/graphics/allocator-aidl2/Android.bp`
- `android/graphics/allocator-aidl2/allocator/android.hardware.graphics.allocator-service.royd.rc` renamed from `allocator.rc`
- `android/scripts/android15-build-readiness-test.sh`
- `android/scripts/graphics-contract-test.sh`
- `docs/development-notes.md`

Validation actually performed:

- `android15-build-readiness-test.sh`, `graphics-contract-test.sh`, `vintf-contract-test.sh`, `hal-contract-test.sh`, and `hal-profile-test.sh` passed.
- `config-check-test.sh` and `aosp-shell-test.sh` passed when rerun separately after the first combined command exceeded the local execution timeout.
- Full `make ci` was attempted repeatedly. In this execution sandbox the combined foreground run was externally terminated during `config-check-test.sh`; the same test passed standalone in 21.64 seconds. Every command in `scripts/ci.sh` was observed passing either before that combined-run termination or in a separate direct run, including `qualification-matrix-test.sh`, `reference-host-qualify-test.sh`, and `go test ./...`. This is not recorded as a successful literal `make ci` run.
- Repository policy scans passed: no em dashes were found, and no prohibited prior-art name references were found outside `docs/acknowledgements.md`. The generated patch passed `git apply --check`, applied cleanly to a fresh copy of the task-044 tree, and the patched tree matched the finished tree byte-for-byte and file-mode-for-file-mode. The finished ZIP round-trip matched the finished tree by the same comparison.
- Roadmap remains 63 checked and 24 open. Task 045 closes no roadmap checkbox because the Android 15 clean-build item still requires the external build to proceed beyond this failure.

External validation still required:

- Rerun the existing `android-15.0.0_r36` x86_64 software build and confirm Kati no longer reports an override for `vendor/etc/init/allocator.rc`.
- Continue through compilation, linking, installation, packaging, and normal VINTF validation. Allocator, mapper, composer VTS and real container boot remain later external gates.

Unresolved failures or questions:

- The supplied log excerpt proves a duplicate install target but does not expose the second install rule, so its owning AOSP module is not recorded as fact.
- No real build has yet compiled the repository-owned Android 15 allocator/mapper/composer family beyond Make graph generation.
- Any next generated-header, compile, link, SELinux, VINTF, packaging, or runtime failure must be treated as new evidence rather than bypassed.

Recommended next task: rerun the same Android 15 build from the patched repository. Task 046 should address only the first new genuine failure, if one appears. If the build completes, task 046 should record and inspect the resulting build/VINTF evidence before starting unrelated architecture work.

Exact external build command on the existing synced build host:

```sh
cd /root/royd
./build.sh \
  --android 15 \
  --arch x86_64 \
  --profile standard \
  --hal-profile graphical \
  --graphics software \
  --sync-jobs 1 \
  --jobs "$(nproc)" \
  --skip-sync \
  --incremental
```

Expected evidence to return: `.work/logs/android15-x86_64-standard-graphical-software.log` plus the first genuine failure with approximately 100 surrounding lines. The immediate success criterion is that Kati passes the prior duplicate `vendor/etc/init/allocator.rc` point and the build proceeds into later Ninja work. If it succeeds further, return lines showing compilation/linking and vendor installation of `android.hardware.graphics.allocator-service.royd`, `mapper.royd`, and `android.hardware.graphics.composer3-service.royd`, plus normal `check_vintf` output. Do not bypass VINTF, SELinux, or build failures.
