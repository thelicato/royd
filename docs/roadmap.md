# Roadmap

This roadmap is ordered by implementation dependency rather than release date. A milestone is complete only when its behaviour can be reproduced from the repository.

## 1. Baseline container boot

- [x] Select and document the initial Android and upstream ReDroid/AOSP baseline.
- [x] Add a repeatable source synchronisation and Android build environment.
- [x] Add reproducible packaging and local OCI image import tooling.
- [x] Add a repeatable single-instance boot validation harness.
- [ ] Boot Android as PID 1 in an OCI container on a documented reference host.
- [ ] Record a known-good build and boot validation from the pinned baseline.
- [x] Add a reproducible reference-host report that captures host metadata and smoke-test evidence.

## 2. Container-owned Binder setup

- [x] Add binderfs-first startup integration that reuses ReDroid's Binder allocator.
- [x] Expose private binderfs devices at the conventional Android device paths.
- [x] Emit actionable Binder compatibility diagnostics to container output.
- [ ] Validate binderfs-only hosts with no pre-created Binder devices.
- [ ] Verify multiple simultaneous containers use isolated Binder contexts.

## 3. Container-native logging and diagnostics

- [x] Add `logcat` forwarding to container stdout and stderr.
- [x] Keep Android `/init` as PID 1.
- [x] Add initial Binder, cgroup, and graphics startup diagnostics.
- [ ] Verify normal `adb logcat` behaviour alongside container log forwarding.
- [ ] Confirm boot failures are understandable from `docker logs` on reference hosts.

## 4. Reproducible runtime examples

- [x] Add a minimal `docker run` example.
- [x] Add a Docker Compose example for a single instance.
- [x] Add configurable local Compose defaults and lifecycle Make targets.
- [x] Document persistent `/data` and ADB access.
- [x] Add a multiple-instance Compose example and repeatable two-instance smoke test.
- [ ] Validate the multiple-instance example on a documented reference host.
- [ ] Document optional GPU device access after host GPU testing.
- [ ] Record the minimum known-good host kernel configuration.

## 5. Low-memory Android profile

- [x] Enable Android low-RAM behaviour with PSI-based `lmkd`.
- [x] Add reduced default display settings for the initial low-memory profile.
- [x] Add a repeatable memory-report command for running containers.
- [x] Add named display profiles for comparative runtime measurements.
- [x] Add a disposable memory-limit sweep with Markdown reporting.
- [ ] Record repeatable idle and workload memory benchmarks on a reference host.
- [ ] Tune `lmkd` and background process behaviour against container memory limits.
- [x] Add a defined minimal Android image profile with conservative build-time package removal.
- [x] Add repeatable standard-versus-minimal image profile comparison reporting.
- [ ] Validate the minimal image profile on a documented reference host and measure its effect.
- [ ] Measure the effect of display resolution, refresh rate, and rendering mode.
- [ ] Publish memory figures only with the exact test profile and workload.

## 6. Privilege reduction

- Inventory every capability and device required by a working privileged container.
- Replace `--privileged` with the smallest practical OCI configuration.
- Document runtime differences across Docker, Podman, and other supported engines.
- Evaluate rootless operation separately if the kernel and runtime model make it practical.

## 7. Optional Go CLI

- [x] Add `royd doctor` for host capability checks.
- [x] Add convenience commands for run, list, shell, logs, stop, and remove workflows.
- [x] Keep command output transparent about the OCI operations being performed.
- [x] Keep every core runtime workflow usable without the CLI.
- [x] Add stronger Linux, Docker daemon, Binder, cgroup v2, and PSI diagnostics.
- [ ] Add ADB convenience commands after the runtime contract is validated on reference hosts.
