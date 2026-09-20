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

## Run

The initial development runtime remains privileged while kernel requirements are established:

```sh
docker run -d --privileged \
  --name royd \
  -v royd-data:/data \
  -p 127.0.0.1:5555:5555 \
  royd:dev
```

Or use the example Compose file:

```sh
docker compose -f runtime/compose.yaml up -d
```

No host Binder devices should be passed explicitly. royd attempts to mount a private binderfs instance inside the container and exposes its Binder devices at `/dev/binder`, `/dev/hwbinder`, and `/dev/vndbinder`.

## Logs

Once Android `logd` is running, royd starts a `logcat` forwarder that writes all Android buffers to PID 1 stdout and stderr. The intended interface is therefore:

```sh
docker logs -f royd
```

ADB remains independent:

```sh
adb connect 127.0.0.1:5555
adb logcat
```

Early royd diagnostics are also written directly to PID 1 output. Binder setup failures should therefore be visible through `docker logs` even before `logcat` starts.

## Host contract

The current MVP expects a Linux host whose running kernel provides Binder IPC and binderfs. royd does not build or install kernel modules at runtime. `--privileged` is temporarily required so Android can mount binderfs and perform the other kernel interactions inherited from the ReDroid baseline.

The runtime has not yet been validated across a host compatibility matrix. Privilege reduction and broader runtime testing remain later milestones.

## Low-memory defaults

The development image currently defaults to a 540 x 960 display at 240 dpi and 30 fps. Android is built with `ro.config.low_ram=true`, PSI-based `lmkd`, and legacy minfree levels disabled. See [`../docs/low-memory.md`](../docs/low-memory.md) for the rationale and measurement rules.

Collect a snapshot from the default `royd` container with:

```sh
make memory-report
```

The repository does not currently prescribe a container memory limit. A reliable minimum will be published only after repeatable boot and workload testing.
