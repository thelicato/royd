<h1 align="center">
  <br>
  <img src="./logo.svg" alt="royd logo" width="220">
</h1>
<p align="center"><b>royd</b></p>

royd is an experimental Android runtime designed for OCI containers. The goal is to run Android directly on the host Linux kernel without QEMU or a guest kernel, while keeping the normal user experience as close as possible to running any other container.

royd is an independent AOSP-based project. Prior art and influences are documented in [`docs/acknowledgements.md`](docs/acknowledgements.md). The project carries its own Android integration, product definitions, runtime helpers, patches, and container tooling.

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

`--privileged` is acceptable for the first working implementation. Reducing privileges to the minimum required capabilities and devices is a later security goal.

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

The first graphics baseline is software-rendered with AOSP SwiftShader, so `/dev/dri` is not required. Host GPU acceleration remains intentionally unsupported until royd owns and validates the complete allocator/composer path. See [`docs/hardware-contract.md`](docs/hardware-contract.md).

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
royd shell
royd stop
royd rm
royd version
```

See [`docs/cli.md`](docs/cli.md) and [`cli/README.md`](cli/README.md) for the current scope.

## Initial roadmap

The current implementation now owns its Android product definitions, Binder allocator, init integration, build profiles, local patch mechanism, OCI packaging, runtime arguments, validation tooling, and optional CLI. The normal build fetches only the pinned AOSP source baseline. The next gate is to build and boot this independent baseline on documented reference hosts, then implement and validate the remaining container-specific hardware and graphics surface.

## Development

Useful development entry points include:

```sh
make check
make android-sync
make android-build-x86_64
make android-package-x86_64
make runtime-import-x86_64
cp runtime/.env.example runtime/.env
make runtime-up
make runtime-logs
make runtime-smoke-test
make runtime-reference-report
make memory-sweep
make cli-test
make cli-build
```

See [`AGENTS.md`](AGENTS.md) for persistent project rules, [`docs/architecture.md`](docs/architecture.md) for the current design, and [`docs/acknowledgements.md`](docs/acknowledgements.md) for project credits.
