# Roadmap

This roadmap is ordered by implementation dependency rather than release date. A milestone is complete only when its behaviour can be reproduced from the repository.

## 1. Baseline container boot

- Select and document the initial Android and upstream ReDroid/AOSP baseline.
- Add a reproducible image build path.
- Boot Android as PID 1 in an OCI container on a documented reference host.
- Keep the first runtime deliberately close to upstream until the container lifecycle is understood.

## 2. Container-owned Binder setup

- Detect Binder IPC and binderfs availability at startup.
- Mount a private binderfs instance from inside the container where supported.
- Allocate `binder`, `hwbinder`, and `vndbinder` dynamically.
- Present the conventional device paths to Android.
- Fail early with actionable logs when the host contract is not met.
- Verify multiple simultaneous containers use isolated Binder contexts.

## 3. Container-native logging and diagnostics

- Forward Android `logcat` to container stdout and stderr.
- Preserve normal `adb logcat` behaviour.
- Add concise startup diagnostics for Binder, cgroups, memory, graphics, and fatal host incompatibilities.
- Make boot failures understandable from `docker logs` alone where practical.

## 4. Reproducible runtime examples

- Add a minimal `docker run` example.
- Add Docker Compose examples for single and multiple instances.
- Document persistent `/data`, ADB access, port allocation, and optional GPU device access.
- Record the minimum known-good host kernel configuration.

## 5. Low-memory Android profile

- Establish repeatable idle and workload memory benchmarks.
- Enable and validate Android low-RAM behaviour where appropriate.
- Tune `lmkd` and background process behaviour against container memory limits.
- Remove unnecessary Android packages and services at build time for a defined minimal profile.
- Measure the effect of display resolution, refresh rate, and rendering mode.
- Publish memory figures only with the exact test profile and workload.

## 6. Privilege reduction

- Inventory every capability and device required by a working privileged container.
- Replace `--privileged` with the smallest practical OCI configuration.
- Document runtime differences across Docker, Podman, and other supported engines.
- Evaluate rootless operation separately if the kernel and runtime model make it practical.

## 7. Optional Go CLI

- Add `royd doctor` for host capability checks.
- Add convenience commands for run, list, shell, logs, stop, and remove workflows.
- Keep command output transparent about the OCI operations being performed.
- Keep every core runtime workflow usable without the CLI.
