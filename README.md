<h1 align="center">
  <br>
  <img src="./logo.svg" alt="royd logo" width="220">
</h1>
<p align="center"><b>royd</b></p>

royd is an experimental Android runtime designed for OCI containers. The goal is to run Android directly on the host Linux kernel without QEMU or a guest kernel, while keeping the normal user experience as close as possible to running any other container.

royd is an independent AOSP-based project. Prior art and influences are documented in [`docs/acknowledgements.md`](docs/acknowledgements.md). The project carries its own Android integration, product definitions, runtime helpers, patches, and container tooling.

## Android versions

royd carries pinned build configurations from Android 8.0 through Android 17. Android 15 remains the default baseline. Android 8.0 through 10 use an explicit legacy compatibility path, while every non-baseline version still requires clean build and boot validation before it can be called supported.

```sh
make android-versions
make android-sync-9
make android-config-check-13
make android-build-x86_64-16
```

See [`docs/android-versions.md`](docs/android-versions.md) for the support matrix and version-selection rules, and [`docs/legacy-android.md`](docs/legacy-android.md) for the Android 8.0 through 10 build, partition, and memfd compatibility path.

> [!IMPORTANT]
> royd is currently in early development. There is no published royd image yet. The repository can build a local development image from the pinned AOSP baseline and repository-owned Android integration, but the independent container boot and graphics path are not yet broadly validated.

## Goals

- Run Android as an OCI container without QEMU or KVM.
- Make plain `docker run` and `docker compose up` the primary interfaces.
- Keep host setup minimal and distribution-independent where the Linux kernel permits it.
- Define royd's required host and virtual hardware contract explicitly instead of inheriting hidden emulator assumptions.
- Prefer private binderfs instances over statically allocated host Binder devices.
- Prefer modern Android and Linux interfaces such as `memfd`, cgroup v2, and PSI-aware memory management.
- Reduce Android memory usage through build-time configuration and removal of unnecessary components.
- Expose Android `logcat` output through container stdout and stderr so `docker logs` is useful by default.
- Support multiple isolated Android containers on one host efficiently.
- Keep any royd CLI optional. The OCI image must remain fully usable without it.

## Intended usage

The target Docker interface is deliberately small. A locally built development image is currently tagged `royd:dev`:

```sh
docker run --privileged \
  -v android-data:/data \
  -p 5555:5555 \
  royd:dev
```

The equivalent Compose configuration is provided in `runtime/compose.yaml` and supports optional local overrides through `runtime/.env`:

```yaml
services:
  android:
    image: ${ROYD_IMAGE:-royd:dev}
    privileged: true
    ports:
      - "${ROYD_ADB_BIND:-127.0.0.1}:${ROYD_ADB_PORT:-5555}:5555"
    volumes:
      - royd-data:/data

volumes:
  royd-data:
    name: ${ROYD_DATA_VOLUME:-royd-data}
```

`--privileged` remains the development baseline. An experimental restricted mode now tests an explicit capability set through the same runtime validation workflows, but it is not yet a supported minimum. See [`docs/security.md`](docs/security.md).

## Runtime model

royd is intended to share the host Linux kernel rather than boot a virtual machine:

```text
Linux host kernel
  -> OCI runtime
    -> royd container
      -> private mount namespace
      -> private binderfs instance
      -> Android init as PID 1
      -> Android userspace
```

Each container should create and manage its own Binder devices where the runtime permits it, while Android continues to see the conventional paths:

```text
/dev/binder
/dev/hwbinder
/dev/vndbinder
```

The host kernel must provide the required Android Binder functionality. royd will not compile or install kernel modules as part of the normal runtime path. Unsupported hosts should fail early with a clear diagnostic instead of failing later during Android boot.

## Container logs

Android `/init` should remain PID 1. Once Android logging is available, the container should forward useful `logcat` output to stdout and stderr so normal container tooling works as expected:

```sh
docker logs -f <container>
```

Direct Android debugging must remain available independently through ADB:

```sh
adb -s localhost:5555 logcat
```

Startup diagnostics should appear in the same container logs and report relevant compatibility information such as Binder support, binderfs initialisation, cgroup mode, graphics mode, and fatal host incompatibilities. Run `make runtime-host-check` for a host-side preflight before starting Android.

The default graphics baseline is software-rendered with AOSP SwiftShader, so `/dev/dri` is not required. royd also has an experimental Android 10+ host GPU path using AOSP Mesa and minigbm with an explicit `/dev/dri` contract. Separate `graphical` and headless-oriented HAL profiles retain the minimum graphics stack required for Android framework boot. See [`docs/hardware-contract.md`](docs/hardware-contract.md), [`docs/graphics.md`](docs/graphics.md), [`docs/host-gpu.md`](docs/host-gpu.md), and [`docs/hal-profiles.md`](docs/hal-profiles.md).

## Low-memory direction

Low memory usage is a core engineering goal, but memory targets are benchmark-driven rather than assumed. The Android build enables supported low-RAM behaviour and PSI-based `lmkd`. Runtime display profiles make framebuffer cost easy to compare without rebuilding Android.

`make memory-report` captures a running instance, while `make memory-sweep` tests disposable candidate memory limits and produces a comparable report. Candidate limits are not treated as supported minimums. See [`docs/low-memory.md`](docs/low-memory.md), [`docs/profiles.md`](docs/profiles.md), and [`docs/benchmarking.md`](docs/benchmarking.md).

## Optional CLI

An optional `royd` CLI now has an initial Go scaffold for host checks and Docker convenience. It must not be required to run an Android container. The current commands are:

```text
royd doctor
royd run
royd ps
royd logs
royd status
royd adb
royd shell
royd stop
royd rm
royd version
```

See [`docs/cli.md`](docs/cli.md) and [`cli/README.md`](cli/README.md) for the current scope.

## Initial roadmap

The current implementation now owns its Android product definitions, Binder allocator, init integration, build profiles, local patch mechanism, software graphics baseline, experimental Android 10+ host-GPU backends, OCI packaging, ADB-over-TCP setup, Docker health checks, runtime arguments, validation tooling, and optional CLI. The normal build fetches only pinned AOSP source. A runtime qualification gate now persists boot, health, graphics, ADB, logging, security, and Binder-isolation evidence for imported images. The next gate is to run clean builds and qualification on documented reference hosts, then validate memory targets and security modes with real workloads.

## Development

Useful development entry points include:

```sh
make ci
make android-matrix-report
make android-build-matrix-test
make android-build-results-report
make check
make android-version-test
make android-memory-compat-test
make android-sync
make android-contract-test
make android-config-check
make android-build-x86_64
make android-package-x86_64
make runtime-import-x86_64
make android-build-headless-x86_64
make runtime-import-headless-x86_64
cp runtime/.env.example runtime/.env
make runtime-up
make runtime-logs
make runtime-smoke-test
make runtime-status
make runtime-adb-check
make runtime-reference-report
make runtime-qualification
make runtime-qualification-matrix
make runtime-qualification-report
make memory-sweep
make cli-test
make cli-build
```

ADB and Docker health-check behaviour are documented in [`docs/adb.md`](docs/adb.md). Lightweight CI and Android matrix reporting are documented in [`docs/ci.md`](docs/ci.md). Clean-build orchestration and resumable build evidence are documented in [`docs/build-validation.md`](docs/build-validation.md). Runtime qualification is documented in [`docs/runtime-qualification.md`](docs/runtime-qualification.md), while [`docs/support-policy.md`](docs/support-policy.md) defines the validation gates required before a release is called supported.

See [`AGENTS.md`](AGENTS.md) for persistent project rules, [`docs/architecture.md`](docs/architecture.md) for the current design, and [`docs/acknowledgements.md`](docs/acknowledgements.md) for project credits.
