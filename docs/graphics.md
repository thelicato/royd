# Graphics

royd has separate `graphical` and `headless` hardware profiles. Both retain the minimum software graphics path required for normal Android framework boot. See [`hal-profiles.md`](hal-profiles.md).

royd uses a software-first graphics contract so Android can start without a host GPU or emulator graphics stack.

## Software path

The current software path is composed from:

- SwiftShader for EGL and OpenGL ES rendering.
- `gralloc.royd`, a repository-owned legacy gralloc module backed by `memfd` allocations.
- AOSP's default `hwcomposer.default` module.
- The AOSP graphics composer service matching each Android generation, used as the Binder/HIDL bridge to the conventional HWC module.

The selected Android composer interfaces are:

| Android | Composer interface |
| --- | --- |
| 8.0-8.1 | 2.1 |
| 9 | 2.2 |
| 10 | 2.3 |
| 11-17 | 2.4 |

This version mapping is configuration, not a support claim. Clean AOSP builds and real boots are still required for every pinned release.

## Buffer allocation

`gralloc.royd` deliberately has no dependency on a physical framebuffer. Buffer allocations are anonymous `memfd` objects and the framebuffer device reports the virtual display dimensions supplied through the royd boot properties.

The initial framebuffer `post` operation is a no-op. SurfaceFlinger and SwiftShader remain responsible for software composition. This is sufficient as an architectural baseline, but it still needs clean-build and runtime validation before the graphical profile can be considered supported.

The allocator currently keeps locked mappings alive until process teardown because the legacy gralloc unlock API does not carry the mapped address. A later mapper implementation should own precise mapping lifetime after the cross-version ABI has been validated.

## Runtime identity

The Android image exposes:

```text
ro.hardware.egl=swiftshader
ro.hardware.gralloc=royd
ro.hardware.hwcomposer=default
vendor.royd.graphics.mode=software
vendor.royd.graphics.allocator=gralloc0-memfd
vendor.royd.graphics.composer=<HIDL version>
```

Use:

```sh
make runtime-graphics-report
```

to capture the selected properties, installed graphics modules, and SurfaceFlinger state from a running container.

## Headless-oriented mode

The `headless` HAL profile does not remove SurfaceFlinger or the allocator/composer stack. It uses the same software graphics foundation with a tiny low-refresh virtual display and removes a conservative set of optional user-facing hardware applications. This avoids claiming that Android can boot normally with its graphics core removed.

## Host GPU mode

An experimental host GPU path is now implemented for Android 10 and newer. It uses AOSP Mesa for EGL/GLES, minigbm for DRM-backed allocation, and an explicit `/dev/dri` runtime device contract. Software rendering remains the default.

The available backends are `host-gpu-generic` and the x86_64-only `host-gpu-intel`. Image identity, packaging, runtime validation, Compose, qualification results, and the optional CLI all keep the selected backend explicit. See [`host-gpu.md`](host-gpu.md). Real host qualification is still required before any GPU/driver combination is called supported.
