# Runtime

The royd runtime is assembled entirely from the pinned AOSP build plus Android integration stored in this repository. Android `/init` remains PID 1.

## Build and import

For x86_64:

```sh
make android-sync
make android-build-x86_64
make android-package-x86_64
make runtime-import-x86_64
```

For the minimal Android image profile:

```sh
make android-build-minimal-x86_64
make android-package-minimal-x86_64
make runtime-import-minimal-x86_64
```

Imported images receive canonical tags derived from the pinned AOSP release, image profile, HAL profile, and architecture, for example:

```text
royd:15.0.0-r36-standard-graphical-amd64
royd:15.0.0-r36-minimal-graphical-amd64
royd:15.0.0-r36-standard-graphical-arm64
royd:15.0.0-r36-standard-headless-amd64
```

Convenience aliases remain available for development. Graphical images keep the short aliases such as `royd:dev`; non-default HAL profiles are explicit, for example `royd:dev-headless`.

The package step extracts AOSP's generated `ramdisk.img` as the container root, preserving its recorded ownership and modes, then adds the built partition images at their normal mount points. It requires system, vendor, system_ext, and product, and includes odm when produced. The archive also contains `/royd-release` with immutable build identity fields and a sidecar manifest with the archive SHA-256 digest.

The importer verifies the archive digest before importing, writes OCI and royd-specific labels, then runs the image contract inspector.

## Run directly

```sh
docker run -d \
  --name royd \
  --privileged \
  -p 127.0.0.1:5555:5555 \
  -v royd-data:/data \
  royd:dev
```

The image defaults to the `default` display profile. Runtime arguments can override it:

```sh
docker run -d \
  --name royd \
  --privileged \
  royd:dev \
  royd.width=360 \
  royd.height=640 \
  royd.dpi=160 \
  royd.fps=30
```

The image entrypoint validates these arguments and then `exec`s Android `/init`. The entrypoint is not a supervisor and does not remain as a separate process. Android init therefore becomes PID 1.

## Security modes

The supported development baseline still uses `--privileged`. royd also carries an experimental restricted mode that replaces it with an explicit capability list for validation work. It is not yet a supported least-privilege configuration.

Test it with:

```sh
make runtime-security-contract-test
make runtime-smoke-test-experimental
make runtime-multi-test-experimental
ROYD_SECURITY_SWEEP_OUTPUT=security-sweep.md make runtime-security-sweep
```

Compose can use the same mode:

```sh
ROYD_SECURITY_MODE=experimental make runtime-up
```

See [`../docs/security.md`](../docs/security.md) for the capability inventory and reduction process.

## Compose

Start the default Compose configuration with:

```sh
make runtime-up
```

Useful commands are:

```sh
make runtime-ps
make runtime-status
make runtime-logs
make runtime-adb-check
make runtime-down
```

Copy `runtime/.env.example` to `runtime/.env` for local overrides. The file is optional.

## Logs

royd forwards Android logcat to PID 1's stdout and stderr, so normal container logging is the primary boot-debugging interface:

```sh
docker logs -f royd
```

ADB remains independent and is configured for TCP port 5555 by the image:

```sh
adb connect 127.0.0.1:5555
adb -s 127.0.0.1:5555 shell
adb -s 127.0.0.1:5555 logcat
```

The image also carries a Docker health check covering Android boot completion, `adbd`, the ADB TCP property, and Binder device readiness. See [`../docs/adb.md`](../docs/adb.md).

## Binder

Each container attempts to mount its own binderfs instance and allocate `binder`, `hwbinder`, and `vndbinder` with the repository-owned `royd-binder-alloc` helper. The devices are exposed at the conventional Android paths under `/dev`.

The host kernel must provide Android Binder IPC and binderfs. royd does not install kernel modules or change the host distribution.

## Runtime profiles

Display profiles live under `runtime/profiles`. Resolve one with:

```sh
runtime/scripts/profile.sh compact
```

Current profiles are `default`, `compact`, and `tablet`. See [`../docs/profiles.md`](../docs/profiles.md).

## Validation

Run the single-instance smoke test with:

```sh
make runtime-smoke-test
```

Run the two-instance test with:

```sh
make runtime-multi-test
```

Run the complete persisted runtime qualification gate with:

```sh
make runtime-qualification
make runtime-qualification-matrix
make runtime-qualification-report
```

The qualification gate also runs the stronger Binder identity isolation test, Docker health, SurfaceFlinger, container-log, security-mode, and host-side ADB checks. See [`../docs/runtime-qualification.md`](../docs/runtime-qualification.md).

Generate a reference-host report with:

```sh
ROYD_REPORT_OUTPUT=reference-host.md make runtime-reference-report
```

Benchmark memory candidates with:

```sh
ROYD_MEMORY_SWEEP_OUTPUT=memory-sweep.md make memory-sweep
```

The current runtime remains experimental. In particular, the independent AOSP product and graphics path must be proven on real reference hosts before the repository claims a supported boot configuration.

## Image contract

Validate the image-contract tooling without a real image:

```sh
make runtime-image-contract-test
```

After importing an x86_64 standard image, inspect it again with:

```sh
make runtime-image-inspect-x86_64
```

The inspector checks the platform architecture, OCI labels, royd image-format labels, entrypoint, and `/royd-release` metadata without booting Android.
