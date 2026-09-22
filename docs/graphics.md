# Graphics

royd has separate `graphical` and `headless` hardware profiles. Both retain the minimum software graphics path required for normal Android framework boot. See [`hal-profiles.md`](hal-profiles.md).

royd uses a software-first graphics contract so Android can start without a host GPU or emulator graphics stack.

## Software path

The default renderer is SwiftShader. The allocator, mapper, and composer family is selected by the pinned Android contract rather than forced through one legacy ABI.

| Android | Allocator / mapper | Composer |
| --- | --- | --- |
| 8.0-8.1 | `gralloc.royd` | HIDL 2.1 plus `hwcomposer.default` |
| 9 | `gralloc.royd` | HIDL 2.2 plus `hwcomposer.default` |
| 10 | `gralloc.royd` | HIDL 2.3 plus `hwcomposer.default` |
| 11-14 | `gralloc.royd` | HIDL 2.4 plus `hwcomposer.default` |
| 15 | AIDL allocator V2 plus `mapper.royd` stable-C V5 | repository-owned composer3 client composition, current V4 source interface with frozen V3 release fallback |
| 16-17 | `gralloc.royd` | HIDL 2.4 plus `hwcomposer.default`, pending branch-specific migration research |

This mapping is configuration, not a support claim. Clean AOSP builds and real boots are still required for every pinned release.

## Android 15 client composition

Android 15 uses repository-owned memfd-backed allocation and a composer3 service built against the current V4 source interface. Android 15 stable-AIDL release handling falls that interface back to the latest frozen V3 wire contract when unfrozen AIDL is disabled. The composer exposes one fixed internal display, advertises no virtual displays or hardware overlay capability, and requests `Composition::CLIENT` for layers it cannot compose. SurfaceFlinger and RenderEngine therefore remain responsible for the actual software composition.

The service reports the configured virtual display dimensions and synthetic vsync timing. It does not provide physical scan-out, readback, HDR conversion, display brightness control, doze modes, or other capabilities that royd has not implemented and validated.

## Legacy buffer allocation

For Android versions still on `gralloc.royd`, allocations are anonymous `memfd` objects and the framebuffer device reports the virtual display dimensions supplied through the royd boot properties. The framebuffer `post` operation remains a no-op.

The legacy allocator keeps locked mappings alive until process teardown because the gralloc0 unlock API does not carry the mapped address. Android 15 instead uses the stable-C mapper path, which owns its mapping and metadata contracts explicitly.

## Runtime identity

The Android image records the selected graphics family through `ro.vendor.royd.graphics_*` properties. A legacy software image also uses `ro.hardware.gralloc=royd` and `ro.hardware.hwcomposer=default`; Android 15 does not set those legacy hardware-module selectors for its modern allocator/composer pair.

Use:

```sh
make runtime-graphics-report
```

to capture the selected properties, installed graphics modules, and SurfaceFlinger state from a running container.

## Headless-oriented mode

The `headless` HAL profile does not remove SurfaceFlinger or the allocator/composer stack. It uses the same version-selected software graphics foundation with a tiny low-refresh virtual display and removes a conservative set of optional user-facing hardware applications. This avoids claiming that Android can boot normally with its graphics core removed.

## Host GPU mode

An experimental host GPU path is configured for Android 10 and newer. It uses AOSP Mesa for EGL/GLES, minigbm for DRM-backed allocation, and an explicit `/dev/dri` runtime device contract. Software rendering remains the default.

The available backends are `host-gpu-generic` and the x86_64-only `host-gpu-intel`. Android 15 selects the modern composer3 service when either backend is requested, but the host-GPU allocator path is not yet qualified against Android 15's modern allocator/mapper contract. Do not treat that combination as build- or runtime-supported until later validation closes the gap. See [`host-gpu.md`](host-gpu.md).
