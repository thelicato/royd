<h1 align="center">
  <br>
  <img src="./logo.svg" alt="royd logo" width="220">
</h1>
<p align="center"><b>royd</b></p>

royd is an experimental Android runtime designed for OCI containers. The goal is to run Android directly on the host Linux kernel without QEMU or a guest kernel, while keeping the normal user experience as close as possible to running any other container.

royd is inspired by ReDroid's native container architecture and by Android-side low-memory optimisation work such as avdslim. It is intended to be container-first rather than an emulator image adapted to run in a container.

> [!IMPORTANT]
> royd is currently in early development. There is no published royd image yet. The repository can build a local development image from the pinned AOSP/ReDroid baseline, but host compatibility is not yet broadly validated.

## Goals

- Run Android as an OCI container without QEMU or KVM.
- Make plain `docker run` and `docker compose up` the primary interfaces.
- Keep host setup minimal and distribution-independent where the Linux kernel permits it.
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

The equivalent Compose configuration should be similarly direct:

```yaml
services:
  android:
    image: royd:dev
    privileged: true
    ports:
      - "127.0.0.1:5555:5555"
    volumes:
      - android-data:/data

volumes:
  android-data:
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

Startup diagnostics should appear in the same container logs and report relevant compatibility information such as Binder support, binderfs initialisation, cgroup mode, graphics mode, and fatal host incompatibilities.

## Low-memory direction

Low memory usage is a core engineering goal, but memory targets are benchmark-driven rather than assumed. The initial profile now enables Android's supported low-RAM mode, keeps PSI-based `lmkd`, and uses a smaller 540 x 960 display by default. A repository memory-report command captures container usage, Android memory totals, and the largest resident processes.

More aggressive work, including package removal, detailed `lmkd` tuning, process limits, rendering changes, and hard memory limits, will be added only with reproducible measurements. See [`docs/low-memory.md`](docs/low-memory.md) for the current profile and measurement rules.

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

The current implementation can build and package the pinned Android baseline, inject royd binderfs and logging integration, import a local OCI image, run repeatable single-instance and two-instance runtime smoke tests, and provide an optional CLI scaffold for host validation and Docker workflows. The next milestone is to execute the runtime tests on documented reference hosts, record known-good boot results, verify Binder isolation beyond mount-level checks, and continue measured low-memory work.

## Development

Useful development entry points include:

```sh
make check
make android-sync
make android-build-x86_64
make android-package-x86_64
make runtime-import-x86_64
make runtime-smoke-test
make cli-test
make cli-build
```

See [`AGENTS.md`](AGENTS.md) for persistent project rules and [`docs/architecture.md`](docs/architecture.md) for the current design.
