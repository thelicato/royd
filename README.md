<h1 align="center">
  <br>
  <img src="./logo.svg" alt="royd logo" width="220">
</h1>
<p align="center"><b>royd</b></p>

royd runs Android directly in OCI containers on the host Linux kernel, without QEMU, KVM or a guest kernel. Docker and Compose are the primary interfaces; no royd daemon or host launcher is required. The optional Go CLI provides convenience commands.

royd is an independent AOSP-based project with owned products, runtime helpers and Android patches. See [acknowledgements](docs/acknowledgements.md) for prior art.

> [!IMPORTANT]
> royd is experimental and has no published image yet. The active baseline is Android 15 x86_64, standard graphical, software rendering and privileged rootful Docker. Local component validation is available; final clean-build and reference-host acceptance remain pending. Read [known limitations](docs/known-limitations.md) and [security](docs/security.md) before use.

## Requirements

- A Linux host with Android Binder IPC and binderfs. royd allocates private Binder devices; it does not compile or install kernel modules.
- Rootful Docker Engine, with Compose v2 for the Compose workflow. Privileged operation is the current baseline.
- The kernel facilities required by the enabled memory and network backends, including the declared BPF/TCX capabilities. See [hardware contract](docs/hardware-contract.md).
- A locally built and imported royd image. Software rendering needs no GPU or `/dev/dri` access.

Run host preflight before booting Android:

```sh
make runtime-host-check
```

The image is built from pinned AOSP and repository-owned integration:

```sh
./build.sh --android 15 --arch x86_64 --jobs "$(nproc)"
```

See [building](docs/building.md) for dependencies, profile selection, packaging and import. The local standard graphical alias is `royd:dev`; [image metadata](docs/runtime.md) records the exact build identity.

## Run Android

```sh
docker run -d --name royd \
  --privileged \
  --tmpfs /dev/socket:rw,nosuid,nodev,noexec,mode=0755 \
  -v royd-data:/data \
  -p 127.0.0.1:5555:5555 \
  royd:dev
```

Android init becomes PID 1. The container creates its own Binder devices and forwards Android logs to stdout/stderr. The named `/data` volume preserves application data across container replacement.

```sh
docker logs -f royd
docker inspect --format '{{.State.Health.Status}}' royd
```

Alternatively, use the provided Compose configuration:

```sh
docker compose -f runtime/compose.yaml up -d
docker compose -f runtime/compose.yaml logs -f
```

Copy `runtime/.env.example` to `runtime/.env` for local overrides. See [runtime usage](docs/runtime.md) and [runtime tooling](runtime/README.md) for lifecycle commands and multi-instance operation.

## Connect with ADB and scrcpy

After Android is ready:

```sh
adb connect 127.0.0.1:5555
adb -s 127.0.0.1:5555 shell
scrcpy -s 127.0.0.1:5555
```

Development ADB authentication is disabled by default. Keep the port loopback-only and use an SSH tunnel for remote access. [ADB configuration](docs/adb.md) covers forwarding and required-key authentication. Authentication alone does not encrypt TCP.

## Profiles and compatibility

The default display is 540x960 at 240dpi and 30fps. Android 15 uses ANGLE over SwiftShader Vulkan, memfd-backed allocation and client composition. [Display/resource profiles](docs/profiles.md) are independent of [image profiles](docs/image-profiles.md) and [HAL profiles](docs/hal-profiles.md).

Low-memory mode is the default. A separate performance resource mode selects normal-RAM framework/Dalvik behaviour; no speed advantage or minimum RAM figure is claimed. Measure a named workload with exact host/image/limits before drawing conclusions. See [memory tuning](docs/low-memory.md) and [benchmarking](docs/benchmarking.md).

Pinned configurations exist from Android 8.0 through 17 and for x86_64/arm64. These are build configurations, not a support guarantee. Other releases, host-GPU modes, Podman/rootless and reduced privileges need separate qualification. See [Android versions](docs/android-versions.md), [runtime engines](docs/runtime-engines.md) and [support policy](docs/support-policy.md).

## Development and validation

```sh
make ci
make android-matrix-report
make runtime-smoke-test
make runtime-qualification
```

Runtime tests require an imported image and create disposable resources. Use fresh evidence directories; preserve failures. Full support also requires a clean build, application/network/endurance checks and reviewed host evidence.

Start with the [development guide](docs/development-notes.md), [architecture](docs/architecture.md), [runtime validation](docs/validation.md), [reference hosts](docs/reference-hosts.md) and [Android 15 completion checklist](docs/android15-completion.md). [AGENTS.md](AGENTS.md) contains repository working rules; the [roadmap](docs/roadmap.md) lists future priorities.
