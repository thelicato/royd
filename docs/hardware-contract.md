# Host and hardware contract

royd is a containerised Android userspace, not a virtual machine. It therefore needs a small set of facilities from the host Linux kernel and OCI runtime.

## Required host facilities

The current runtime contract requires:

- Linux as the host kernel.
- An OCI runtime, with Docker as the currently tested interface.
- Android Binder IPC with binderfs advertised by the host kernel.
- Permission for the container to mount its own binderfs instance.
- Normal Linux namespaces, `memfd`, procfs, sysfs, and tmpfs facilities expected by modern Android userspace.

Privileged mode remains the development baseline. An experimental reduced profile now removes `--privileged` and tests an explicit capability set. It is not yet a supported minimum. See [`security.md`](security.md).

Run the host-side preflight with:

```sh
make runtime-host-check
```

A missing hard requirement returns a non-zero exit status. cgroup v2 and memory PSI are reported as warnings because Android may still start without them, although low-memory behaviour can be worse.

## Binder

Each royd container mounts a private binderfs instance and dynamically allocates `binder`, `hwbinder`, and `vndbinder`. Android sees them at the conventional paths under `/dev`.

No host-side Binder device naming convention is part of the royd contract.

## Graphics baseline

The software-first graphics baseline uses SwiftShader for EGL and OpenGL ES together with the repository-owned `gralloc.royd` allocator. AOSP supplies the version-matched composer service and conventional `hwcomposer.default` bridge. The royd product sets:

```text
ro.hardware.egl=swiftshader
ro.hardware.gralloc=royd
ro.hardware.hwcomposer=default
ro.opengles.version=196610
```

This means `/dev/dri` is not required for the software-rendering baseline.

The runtime records the selected path as:

```text
vendor.royd.graphics.mode=software
```

See [`graphics.md`](graphics.md) for the cross-version composer mapping and allocator contract.

Host GPU acceleration is deliberately not exposed as a supported mode yet. A future host mode must define the buffer allocator, graphics composer, render-node exposure, permissions, and fallback behaviour as one tested contract instead of merely passing `/dev/dri` into the container.

## Runtime diagnostics

During early Android boot, `royd-hardware-setup` records:

```text
vendor.royd.host.cgroup
vendor.royd.host.psi
vendor.royd.host.dri
vendor.royd.graphics.mode
```

The same information is written to container logs with the `[royd]` prefix.

## Board configuration

royd owns its x86_64 and arm64 board configuration. Both board files explicitly declare that the container build has no bootloader and no guest kernel, define the target CPU architecture, and reuse AOSP's shared GSI board defaults for common image and platform settings.

The product layer likewise avoids AOSP emulator product definitions and `emulator_vendor.mk`. A shared `container_common.mk` composes the system from upstream AOSP userspace building blocks, while royd-specific runtime integration remains under `vendor/royd`.

Reusing upstream AOSP build primitives is expected. The independence boundary is that royd does not import another Android-container project's product, board, vendor, manifest, image, or patch layer.
