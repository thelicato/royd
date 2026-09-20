# Host and hardware contract

royd is a containerised Android userspace, not a virtual machine. It therefore needs a small set of facilities from the host Linux kernel and OCI runtime.

## Required host facilities

The current runtime contract requires:

- Linux as the host kernel.
- An OCI runtime, with Docker as the currently tested interface.
- Android Binder IPC with binderfs advertised by the host kernel.
- Permission for the privileged development container to mount its own binderfs instance.
- Normal Linux namespaces, `memfd`, procfs, sysfs, and tmpfs facilities expected by modern Android userspace.

The development runtime still uses `--privileged`. The exact capability and device set required to remove that flag remains future work.

Run the host-side preflight with:

```sh
make runtime-host-check
```

A missing hard requirement returns a non-zero exit status. cgroup v2 and memory PSI are reported as warnings because Android may still start without them, although low-memory behaviour can be worse.

## Binder

Each royd container mounts a private binderfs instance and dynamically allocates `binder`, `hwbinder`, and `vndbinder`. Android sees them at the conventional paths under `/dev`.

No host-side Binder device naming convention is part of the royd contract.

## Graphics baseline

The first self-contained graphics baseline uses SwiftShader for EGL and OpenGL ES. The royd product includes the AOSP SwiftShader libraries and sets:

```text
ro.hardware.egl=swiftshader
ro.opengles.version=196610
```

This means `/dev/dri` is not required for the software-rendering baseline.

The runtime records the selected path as:

```text
vendor.royd.graphics.mode=software
```

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

## Remaining AOSP device dependency

The current royd products still inherit AOSP's `aosp_x86_64.mk` and `aosp_arm64.mk`. These are upstream AOSP files, not ReDroid dependencies, but they are not the final hardware abstraction for royd. In particular, the x86_64 AOSP product is emulator-oriented and inherits generic emulator vendor configuration.

Replacing that inheritance with royd-owned board and product definitions is a required milestone before the container hardware layer can be considered independent end to end.
