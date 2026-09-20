# Runtime integration

## Android vendor layer

royd installs a small `vendor/royd` project into the synchronised Android source tree. `device/redroid/redroid.mk` inherits `vendor/royd/royd.mk`, which adds the royd init configuration and helper scripts to the vendor image.

The integration is applied after the upstream ReDroid patch set. It is intentionally separate from ReDroid source patches so the royd-specific surface stays small and reviewable.

## Binder startup

ReDroid already ships a `binder_alloc` utility for creating Binder devices from binderfs. royd reuses that utility rather than maintaining another Binder ioctl implementation.

During Android `early-init`, `royd-binder-setup`:

1. Creates `/dev/binderfs` if necessary.
2. Mounts a private binderfs instance if `binder-control` is not already available.
3. Allocates `binder`, `hwbinder`, and `vndbinder` when they are missing.
4. Exposes those devices through the conventional `/dev` paths.
5. Prints basic cgroup and graphics diagnostics to container output.

The setup is designed to be idempotent because the upstream ReDroid init configuration may also have performed part of the binderfs setup. This lets royd move towards container-owned Binder setup without immediately forking the upstream allocator.

A missing binderfs implementation is considered a host compatibility failure. royd reports it explicitly and does not attempt DKMS, kernel module installation, or distribution-specific repair.

## Container logging

`init.royd.rc` waits for Android `logd` to report itself running, then starts `royd-logcat`. The helper executes:

```text
logcat -b all -v threadtime
```

and connects its stdout and stderr to `/proc/1/fd/1` and `/proc/1/fd/2`. Android `/init` therefore remains PID 1 while OCI logging captures Android logs.

This does not consume or disable the Android logging buffers. `adb logcat` remains available normally.

## Root filesystem packaging

The runtime archive is produced from the Android build output rather than from a conventional Dockerfile. The package script mounts `system.img` and `vendor.img` read-only, archives the system image as the container root, and places the vendor image at `/vendor` in the same archive.

The archive is imported with an entrypoint equivalent to:

```text
/init androidboot.hardware=redroid androidboot.use_memfd=true
```

Display defaults are stored separately as the OCI image command, currently 540 x 960 at 240 dpi and 30 fps. Keeping essential boot arguments in the entrypoint and tunable display arguments in the command lets normal Docker arguments replace the display profile without dropping the required ReDroid hardware and `memfd` settings.

This follows the same basic image assembly model used by upstream ReDroid while keeping royd's build and runtime steps reproducible from this repository.
