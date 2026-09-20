# royd

royd is an experimental Android runtime designed for OCI containers. The goal is to run Android directly on the host Linux kernel without QEMU or a guest kernel, while keeping the normal user experience as close as possible to running any other container.

royd is inspired by ReDroid's native container architecture and by Android-side low-memory optimisation work such as avdslim. It is intended to be container-first rather than an emulator image adapted to run in a container.

> [!IMPORTANT]
> royd is currently in early development. There is no runnable royd image yet. Commands in this document describe the intended interface unless stated otherwise.

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

The target Docker interface is deliberately small:

```sh
docker run --privileged \
  -v android-data:/data \
  -p 5555:5555 \
  ghcr.io/<owner>/royd:<tag>
```

The equivalent Compose configuration should be similarly direct:

```yaml
services:
  android:
    image: ghcr.io/<owner>/royd:<tag>
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

Low memory usage is a core engineering goal, but memory targets will be benchmark-driven rather than assumed. Areas to investigate include:

- `ro.config.low_ram=true` and related Android framework behaviour.
- PSI-aware `lmkd` configuration.
- Cached and background process limits.
- Reduced display resolution and refresh rate profiles.
- Optional host GPU acceleration and efficient software rendering.
- Build-time removal or optionalisation of Android components that are unnecessary for defined image profiles.
- Efficient shared immutable layers and per-instance `/data` storage.

Functionality should be removed only as part of clearly defined image profiles with reproducible tests.

## Optional CLI

A future `royd` CLI may be written in Go for convenience. It must not be required to run an Android container. Possible commands include:

```text
royd doctor
royd run
royd ps
royd shell
royd logs
royd stop
royd rm
```

The CLI may perform host checks, generate or execute container commands, and simplify ADB and multi-instance workflows.

## Initial roadmap

The first implementation milestones are:

1. Establish the minimal container boot path and host capability checks.
2. Mount binderfs and create Binder devices from inside the container.
3. Boot an Android userspace with `/init` as PID 1.
4. Forward `logcat` to container stdout and stderr.
5. Produce a reproducible OCI image build.
6. Measure baseline memory use and define low-memory image profiles.
7. Reduce container privileges after the architecture is proven.
8. Add the optional Go CLI without making it a runtime dependency.

## Development

Project-wide architecture decisions and contribution rules are recorded in [`AGENTS.md`](AGENTS.md). The initial Android source and build workflow is documented in [`docs/building.md`](docs/building.md). In particular, documentation and user-facing text use British English, em dashes are avoided, and changes are kept to one reviewable atomic task at a time.
