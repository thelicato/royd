# Host and hardware contract

royd is a containerised Android userspace, not a virtual machine. It therefore needs a small set of facilities from the host Linux kernel and OCI runtime.

## Required host facilities

The current runtime contract requires:

- Linux as the host kernel.
- A high-level container engine, with rootful Docker Engine as the configured primary interface. See [`runtime-engines.md`](runtime-engines.md) for the distinction between image portability and engine qualification.
- Android Binder IPC with binderfs advertised by the host kernel.
- Permission for the container to mount its own binderfs instance.
- Normal Linux namespaces, `memfd`, procfs, sysfs, and tmpfs facilities expected by modern Android userspace.

Privileged mode remains the development baseline. An experimental reduced profile now removes `--privileged` and tests an explicit capability set. It is not yet a supported minimum. See [`security.md`](security.md).

Run the host-side preflight with:

```sh
make runtime-host-check
```

A missing hard requirement returns a non-zero exit status. cgroup v2 and memory PSI are reported as warnings because Android may still start without them, although low-memory behaviour can be worse. Rootless feasibility has an additional user-namespace binderfs probe documented in [`rootless.md`](rootless.md).

## Kernel evidence contract

Capture image-independent kernel evidence with:

```sh
make runtime-kernel-evidence
```

The machine-readable output records the kernel release and architecture, binderfs advertisement, cgroup v2 controllers, memory PSI, active LSMs when readable, the unprivileged user-namespace sysctl when present, DRM render nodes, and relevant Kconfig values. Kconfig is read from `/proc/config.gz`, `/boot/config-$(uname -r)`, or the kernel build tree when one is available. An unreadable Kconfig is recorded as `unknown` rather than inferred from the distribution name.

The versioned contract in `runtime/kernel/config-contract.tsv` classifies Binder IPC and binderfs as required configuration evidence, cgroup and PSI options as preferred, and rootless or DRM options as path-specific. Live capability checks remain authoritative for the running host. A matching Kconfig does not prove that Android boots, and this contract is not the minimum known-good host kernel until a successful reference-host qualification supplies that evidence.

## Binder

Each royd container mounts a private binderfs instance and dynamically allocates `binder`, `hwbinder`, and `vndbinder`. Android sees them at the conventional paths under `/dev`.

No host-side Binder device naming convention is part of the royd contract.

## Graphics baseline

The software-first graphics baseline uses SwiftShader for EGL and OpenGL ES. Android 15 selects the repository-owned AIDL allocator V2, stable-C mapper V5, and a composer3 client-composition service built against the current V4 source interface with frozen V3 release fallback. Other pinned versions retain the legacy `gralloc.royd` and `hwcomposer.default` family until their branch contracts are migrated separately.

The software path does not require `/dev/dri`. The runtime records the selected backend and the version-selected allocator/composer identities through `vendor.royd.graphics.*` properties.

See [`graphics.md`](graphics.md) for the cross-version graphics-family mapping and capability boundaries.

Experimental host-GPU backends are configured for Android 10 and newer. They combine AOSP Mesa, minigbm, explicit `/dev/dri` passthrough, render-node diagnostics, backend-specific image identity, and software-rendered fallback images. Android 15 uses the modern composer3 service, but its host-GPU allocator path still requires separate build and runtime qualification.

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
