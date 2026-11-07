# Graphics

royd has separate `graphical` and `headless` hardware profiles. Both retain the minimum software graphics path required for normal Android framework boot. See [`hal-profiles.md`](hal-profiles.md).

royd uses a software-first graphics contract so Android can start without a host GPU or emulator graphics stack.

## Software path

The software renderer is version-selected. Android 15 uses AOSP ANGLE from the system image; the other pinned releases retain the existing SwiftShader contract until their software path is validated separately. The allocator, mapper, and composer family is selected by the pinned Android contract rather than forced through one legacy ABI.

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

For `android-15.0.0_r36`, AOSP `base_system.mk` already installs `libEGL_angle`, `libGLESv1_CM_angle`, and `libGLESv2_angle`. royd selects AOSP `angle_default.mk`, which sets `persist.graphics.egl=angle`, and also packages SwiftShader's Vulkan ICD as `vulkan.pastel` with `ro.hardware.vulkan=pastel`. This is the CPU-only software stack: ANGLE provides EGL/GLES and SwiftShader provides its Vulkan backend. royd does not invent an `angle_supported.mk` dependency or require `ro.hardware.egl=angle`.

Android 15 uses repository-owned memfd-backed allocation and a composer3 service built against the current V4 source interface. Android 15 stable-AIDL release handling falls that interface back to the latest frozen V3 wire contract when unfrozen AIDL is disabled. The composer exposes one fixed internal display, advertises no virtual displays or hardware overlay capability, and requests `Composition::CLIENT` for layers it cannot compose. SurfaceFlinger and RenderEngine therefore remain responsible for the actual software composition.

Because this client-only display has no physical scan-out, it cannot provide a physical presentation timestamp. RenderEngine supplies an empty client-target acquire fence when its synchronous work is already complete. The composer therefore advertises `PRESENT_FENCE_IS_NOT_RELIABLE` and omits the present-fence result, which makes SurfaceFlinger disable presentation-latency tracking for this display. It never fabricates a fence from `eventfd`, and runtime qualification rejects invalid-present-fence diagnostics.

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

Qualifying this Android 15 host-GPU path is required for competitive interactive performance on machines with suitable DRM render nodes. Adding RAM alone cannot remove the CPU cost of ANGLE over SwiftShader. Software and host-GPU benchmarks must therefore be reported separately.

## Android 15 software Vulkan presentation ordering

Patch0085 makes the Android Vulkan loader submit a presentation batch's binary semaphore waits once before releasing its images. It applies only on x86_64 with `ROYD_CONTAINER=1`, an SELinux enforcement-interface probe failing exactly with `ENOENT`, and a queried `VK_DRIVER_ID_GOOGLE_SWIFTSHADER`. Missing property-query support, another driver and every other environment retain the stock path. Zero-wait batches require no extra submission. Submission errors are returned for the batch and its per-swapchain results; surface damage, timing, present fences/modes and image-release errors retain their existing handling.

The pinned SwiftShader Android release hook ignores its wait-semaphore arguments and drains only its own queue before returning an already-signalled native fence. A producer on another queue/device can therefore remain pending when an image is released. Android's [Vulkan implementation contract](https://source.android.com/docs/core/graphics/implement-vulkan#release-images) requires those dependencies to finish. The loader also forwards the same waits to each swapchain, so adding consumption independently to every image release would consume a batch's waits repeatedly. The scoped loader submission handles the dependencies once and leaves SwiftShader's existing synchronous queue drain and image preparation intact. It emits one `ROYD: consuming software Vulkan presentation semaphores once per batch` marker per process after the first successful wait submission. An unused path need not emit it.

Task182 reproduces premature release on unchanged `3ba4f8c1f19e` through both the private driver hook and public Vulkan swapchains. A second logical device has submitted binary-semaphore signals behind a timeline wait; a controlled host signal later releases that producer. The public one/two-swapchain failures and explicit-wait positive controls retain correct readback of every pixel. These establish presentation ordering, not the cause of task181's HWUI/BufferQueue hand-off stalls, older blank samples, focus ANRs or startup pre-watchdogs. Rebuilt `2493555fb675` from implementation `570189a` passes those controls, full pre/post runtime, complete qualification including both Binder companions and five-minute scrcpy (303 seconds, 135 cycles, all 4,828 recorded frames decoded). Packaged loader/debug build ID is `d12cd92ac0e1e1e655f69b66357bdcfb`; twelve selected framework/app/network/SwiftShader/composer/entrypoint artefacts remain byte-identical to task177. Each participating process emits the marker once. Eight discrete samples show content/transitions without a blank sample, but eight streaming hand-off warnings remain. This closes the ordering gate only, with no continuous visual, historical-failure or speed claim. Full evidence and failed controls remain in `.work/task182`.

Build the diagnostic separately from the product image:

```sh
./runtime/scripts/vulkan-present-build.sh .work/vulkan-present-probe-new
```

Use an owned disposable Android 15 software container and a fresh in-container directory. Verify its init environment before supplying the container gate to an exec process, which does not inherit init's exported environment:

```sh
docker exec "$container" sh -ec 'tr "\000" "\n" < /proc/1/environ | grep -Fxq ROYD_CONTAINER=1'
probe_dir=$(docker exec "$container" mktemp -d /data/local/tmp/royd-vulkan-present.XXXXXX)
docker cp .work/vulkan-present-probe-new/probe "$container:$probe_dir/probe"
docker exec "$container" chmod 0755 "$probe_dir/probe"
docker exec "$container" env ROYD_CONTAINER=1 timeout 15 "$probe_dir/probe" 0 1 0
docker exec "$container" env ROYD_CONTAINER=1 timeout 15 "$probe_dir/probe" 1 1 0
docker exec "$container" env ROYD_CONTAINER=1 timeout 15 "$probe_dir/probe" 2 2 0
docker exec "$container" env ROYD_CONTAINER=1 timeout 15 "$probe_dir/probe" 1 1 1
docker exec "$container" env ROYD_CONTAINER=1 timeout 15 "$probe_dir/probe" 2 2 1
```

Arguments are wait count, swapchain count and explicit diagnostic wait submission. The last two cases exercise the positive control without relying on the loader fix. The probe requires the CPU SwiftShader identity, real ImageReader swapchains, pending imported binary-semaphore producers and exact red/green pixel readback. Its host-signal receipt assertion targets this known synchronous SwiftShader path, not generic Vulkan return latency or every renderer. No wait lacking a pending signal is submitted. Retain command exits, source/ELF checksums, full logs/inspect and pre/post runtime checks before removing the owned container. Repository contracts alone do not qualify the rebuilt path or ordinary-app permissions.
