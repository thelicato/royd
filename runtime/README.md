# Runtime image

The royd runtime is assembled from the Android `system.img` and `vendor.img` produced by the pinned AOSP/ReDroid build. Android `/init` remains the image entrypoint and PID 1.

## Build and import

Build Android, package the root filesystem, then import it into Docker:

```sh
make android-build-x86_64
make android-package-x86_64
make runtime-import-x86_64
```

The arm64 equivalents are `android-build-arm64`, `android-package-arm64`, and `runtime-import-arm64`.

The package step runs inside the privileged Android builder because it mounts the generated system and vendor images read-only. It writes `.work/runtime/royd-<arch>.tar`. The import step turns that archive into `royd:dev` with `/init` as the entrypoint.

## Compose workflow

The default local workflow uses `runtime/compose.yaml`. Copy the example environment file once if you want local overrides:

```sh
cp runtime/.env.example runtime/.env
```

The defaults work without editing the file:

```text
ROYD_IMAGE=royd:dev
ROYD_CONTAINER=royd
ROYD_DATA_VOLUME=royd-data
ROYD_ADB_BIND=127.0.0.1
ROYD_ADB_PORT=5555
```

Start, inspect, follow logs, and stop the instance with:

```sh
make runtime-up
make runtime-ps
make runtime-logs
make runtime-down
```

These targets are thin wrappers around Docker Compose. They use `runtime/.env` automatically when it exists and otherwise rely on the defaults embedded in the Compose file. The equivalent direct command remains fully supported:

```sh
docker compose -f runtime/compose.yaml up -d
```

To use local overrides, copy `runtime/.env.example` to `runtime/.env`.

## Run directly

The initial development runtime remains privileged while kernel requirements are established:

```sh
docker run -d --privileged \
  --name royd \
  -v royd-data:/data \
  -p 127.0.0.1:5555:5555 \
  royd:dev
```

No host Binder devices should be passed explicitly. royd attempts to mount a private binderfs instance inside the container and exposes its Binder devices at `/dev/binder`, `/dev/hwbinder`, and `/dev/vndbinder`.

## Logs

Once Android `logd` is running, royd starts a `logcat` forwarder that writes all Android buffers to PID 1 stdout and stderr. The intended interface is therefore:

```sh
docker logs -f royd
```

or:

```sh
make runtime-logs
```

ADB remains independent:

```sh
adb connect 127.0.0.1:5555
adb logcat
```

Early royd diagnostics are also written directly to PID 1 output. Binder setup failures should therefore be visible through `docker logs` even before `logcat` starts.

## Runtime validation

After importing `royd:dev`, run a disposable single-instance boot check with:

```sh
make runtime-smoke-test
```

The test waits for Android boot completion, verifies the conventional Binder devices and binderfs mount, confirms low-RAM mode and logcat forwarding, and checks that the binderfs readiness diagnostic reached Docker logs. It removes its temporary container and `/data` volume on exit.

A two-instance test is also available:

```sh
make runtime-multi-test
```

This boots two containers concurrently with separate `/data` volumes and applies the same assertions to both. It validates concurrent binderfs setup but does not claim to prove cross-context Binder IPC isolation. See [`../docs/validation.md`](../docs/validation.md) for the full validation contract and reference-host recording template.

Collect a shareable Markdown report containing host metadata and both smoke-test results with:

```sh
make runtime-reference-report
```

Set `ROYD_REPORT_OUTPUT=reference-host.md` to save it instead of printing it to stdout.

For manual multi-instance testing with ADB:

```sh
docker compose -f runtime/compose.multi.yaml up -d
```

The example exposes the two instances on `127.0.0.1:5555` and `127.0.0.1:5556` by default. The image, container names, data volumes, bind address, and host ports can all be overridden through environment variables.

## Host contract

The current MVP expects a Linux host whose running kernel provides Binder IPC and binderfs. royd does not build or install kernel modules at runtime. `--privileged` is temporarily required so Android can mount binderfs and perform the other kernel interactions inherited from the ReDroid baseline.

The runtime has not yet been validated across a host compatibility matrix. Privilege reduction and broader runtime testing remain later milestones.

## Low-memory defaults

The development image currently defaults to a 540 x 960 display at 240 dpi and 30 fps. Android is built with `ro.config.low_ram=true`, PSI-based `lmkd`, and legacy minfree levels disabled. Named display profiles are available under `runtime/profiles/`. See [`../docs/profiles.md`](../docs/profiles.md) and [`../docs/low-memory.md`](../docs/low-memory.md).

Collect a snapshot from the default `royd` container with:

```sh
make memory-report
```

The repository does not currently prescribe a container memory limit. Run `make memory-sweep` to test disposable candidate limits and produce a comparable report. See [`../docs/benchmarking.md`](../docs/benchmarking.md). A reliable minimum will be published only after repeatable boot and workload testing.
