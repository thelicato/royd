# Roadmap

This roadmap is ordered by implementation dependency rather than release date. A milestone is complete only when its behaviour can be reproduced from this repository.

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
- [ ] Build both royd products from a clean AOSP checkout.
- [ ] Boot Android as PID 1 in an OCI container on a documented reference host.
- [ ] Record a known-good build and boot validation from the independent baseline.

## 2. Container-owned Binder setup

- [x] Add binderfs-first startup integration.
- [x] Implement the Binder allocation helper inside this repository.
- [x] Expose private binderfs devices at the conventional Android device paths.
- [x] Emit actionable Binder compatibility diagnostics to container output.
- [ ] Validate binderfs-only hosts with no pre-created Binder devices.
- [ ] Verify multiple simultaneous containers use isolated Binder contexts.

## 3. Container-native Android hardware surface

- [x] Stop inheriting AOSP emulator product definitions and `emulator_vendor.mk`.
- [x] Add royd-owned x86_64 and arm64 board configuration.
- [ ] Build both royd-owned board configurations from a clean AOSP checkout and resolve any missing HAL or image requirements.
- [x] Add a repository-owned memfd gralloc module and version-matched AOSP composer bridge for the software path.
- [ ] Validate the software graphics path with clean builds and real SurfaceFlinger boots across representative Android generations.
- [ ] Implement optional host GPU rendering through explicit `/dev/dri` access.
- [x] Define initial graphical and headless-oriented HAL profiles with explicit image identity.
- [ ] Validate the exact runtime HAL and service set for both profiles across representative Android generations.
- [ ] Make runtime display parameters take effect without relying on emulator-specific services.

## 4. Container-native logging and diagnostics

- [x] Add `logcat` forwarding to container stdout and stderr.
- [x] Keep Android `/init` as PID 1.
- [x] Add Binder, cgroup, and graphics startup diagnostics.
- [x] Add a reproducible reference-host report.
- [ ] Verify normal `adb logcat` behaviour alongside container log forwarding.
- [ ] Confirm boot failures are understandable from `docker logs` on reference hosts.

## 5. Reproducible runtime examples

- [x] Add a minimal `docker run` example.
- [x] Add a configurable Docker Compose example.
- [x] Add Compose lifecycle Make targets.
- [x] Add persistent `/data` and ADB configuration.
- [x] Add multiple-instance Compose and smoke-test workflows.
- [ ] Validate the multiple-instance example on a documented reference host.
- [ ] Record the minimum known-good host kernel configuration.

## 6. Low-memory Android profiles

- [x] Enable Android low-RAM behaviour with PSI-based `lmkd`.
- [x] Add named display profiles.
- [x] Add repeatable memory reports and memory-limit sweeps.
- [x] Add standard and minimal build-time Android image profiles.
- [x] Add standard-versus-minimal comparison reporting.
- [ ] Record repeatable idle and workload memory benchmarks on a reference host.
- [ ] Tune `lmkd` and background process behaviour against container memory limits.
- [ ] Expand package removal only after compatibility testing.
- [ ] Publish memory figures only with the exact test profile and workload.

## 7. Privilege reduction

- [x] Add an explicit experimental capability inventory and reduced Compose/Docker mode.
- [x] Run the existing smoke, multi-instance, benchmark, CLI, and report tooling through selectable security modes.
- [x] Add a security-mode comparison report with captured failure diagnostics.
- [ ] Validate the experimental mode on a known-good reference host.
- [ ] Remove capabilities that are not demonstrated requirements.
- [ ] Record any required seccomp, LSM, device, cgroup, or system-path exceptions.
- [ ] Promote the smallest validated OCI configuration to the default.
- [ ] Document runtime differences across Docker, Podman, and other supported engines.
- [ ] Evaluate rootless operation separately.

## 8. Optional Go CLI

- [x] Add host capability checks.
- [x] Add run, list, shell, logs, stop, and remove workflows.
- [x] Keep command output transparent about Docker operations.
- [x] Keep every core runtime workflow usable without the CLI.
- [ ] Add ADB convenience commands after the independent runtime contract is validated.

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
- design and benchmark a host GPU mode only after the software path is stable

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
