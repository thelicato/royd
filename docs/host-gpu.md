# Host GPU acceleration

royd has an experimental host GPU path for Android 10 and newer. Software rendering remains the default and the only portable graphics baseline.

## Backends

`ROYD_GRAPHICS_BACKEND` accepts:

| Backend | Android | Architecture | Allocator | EGL | Host requirement |
| --- | --- | --- | --- | --- | --- |
| `software` | 8.0-17 | x86_64, arm64 | `gralloc.royd` | SwiftShader | none |
| `host-gpu-generic` | 10-17 | x86_64, arm64 | `gralloc.minigbm` | Mesa | `/dev/dri` |
| `host-gpu-intel` | 10-17 | x86_64 | `gralloc.minigbm_intel` | Mesa | `/dev/dri` with a compatible Intel DRM driver |

The generic minigbm backend is not a claim of universal DRM support. Individual host drivers must be qualified before they are documented as supported.

## Build

Build and import the generic backend with:

```sh
make android-build-host-gpu-x86_64
make android-package-host-gpu-x86_64
make runtime-import-host-gpu-x86_64
```

The generic backend is also available for arm64 builds:

```sh
make android-build-host-gpu-arm64
make android-package-host-gpu-arm64
make runtime-import-host-gpu-arm64
```

For the Intel-specific x86_64 allocator:

```sh
make android-build-host-gpu-intel-x86_64
make android-package-host-gpu-intel-x86_64
make runtime-import-host-gpu-intel-x86_64
```

Canonical image identity includes the graphics backend. Development aliases include `royd:dev-host-gpu-generic` and `royd:dev-host-gpu-intel`.

## Runtime

Direct Docker runs must expose the DRM device directory:

```sh
docker run --privileged \
  --device=/dev/dri:/dev/dri \
  -p 127.0.0.1:5555:5555 \
  royd:dev-host-gpu-generic
```

Compose automatically adds `runtime/compose.gpu.yaml` when `ROYD_GRAPHICS_BACKEND` is set to a host GPU backend.

The optional CLI can do the same:

```sh
royd run --graphics host-gpu-generic
```

## Contract

The host GPU images use AOSP's Mesa Android EGL/GLES implementation and minigbm allocator modules. AOSP itself carries `libGLES_mesa`, and minigbm provides gralloc modules backed by DRM buffer allocation. The royd runtime maps `/dev/dri` into the container and verifies that at least one render node is available.

The composer follows the Android-version contract: Android 15 selects royd's composer3 client-composition service built against the current V4 source interface, while versions not yet migrated retain `hwcomposer.default`. Host GPU mode does not claim physical display scan-out from the host. royd remains a virtual-display/container runtime. The Android 15 host-GPU allocator path is not yet qualified against its modern allocator/mapper contract, so that combination remains an implementation and validation gap.

## Status

The implementation and local contract tests are complete. Real host qualification is still required. Until that evidence exists, host GPU mode is experimental and must not be presented as a supported default.
