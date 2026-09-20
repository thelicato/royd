# Runtime integration

## Host contract

Before running a locally imported image, check the host with:

```sh
make runtime-host-check
```

The current hard requirement is a Linux host whose kernel advertises binderfs. Docker must also be installed and reachable. cgroup v2 and memory PSI are strongly preferred and reported as warnings when unavailable.

The portable graphics baseline is AOSP SwiftShader and does not require `/dev/dri`. Android 10 and newer also have experimental AOSP Mesa/minigbm host-GPU backends with explicit `/dev/dri` passthrough. These backends are implemented but remain unqualified on real hosts. See [`hardware-contract.md`](hardware-contract.md) and [`host-gpu.md`](host-gpu.md).

## Repository-owned Android layer

royd owns both sides of its Android integration. `device/royd` defines the royd products and `vendor/royd` supplies container-specific userspace components. Source synchronisation copies both projects into the pinned AOSP tree.

No external Android container device tree, vendor tree, patch repository, or runtime helper is required.

## Binder startup

royd includes its own small `royd-binder-alloc` binary. It uses the Linux binderfs `BINDER_CTL_ADD` ioctl to request Binder devices from the container's private binderfs mount.

During Android `early-init`, `royd-binder-setup`:

1. Creates `/dev/binderfs` if necessary.
2. Mounts a private binderfs instance if `binder-control` is not already available.
3. Allocates `binder`, `hwbinder`, and `vndbinder` when they are missing.
4. Exposes those devices through `/dev/binder`, `/dev/hwbinder`, and `/dev/vndbinder`.
5. Prints basic cgroup and graphics diagnostics to container output.

A missing binderfs implementation is considered a host compatibility failure. royd does not attempt DKMS, kernel module installation, or distribution-specific repair.

Linux binderfs is specifically designed to provide independent Binder device sets per binderfs instance, which is the isolation model royd intends to use for multiple containers.

## Container logging

`init.royd.rc` waits for Android `logd` to report itself running, then starts `royd-logcat`. The helper runs `logcat -b all -v threadtime` and connects its output to PID 1's stdout and stderr. Android `/init` therefore remains PID 1 while normal OCI logging captures Android logs.

This does not consume or disable the Android logging buffers. `adb logcat` remains available independently. royd configures `adbd` to listen on TCP port 5555 and the OCI image exposes that port. See [`adb.md`](adb.md).

## Runtime display configuration

Runtime profiles use royd-owned OCI arguments:

```text
royd.width
royd.height
royd.dpi
royd.fps
```

The OCI entrypoint validates those values, writes `/royd-runtime.conf`, and then uses `exec /init`. Android init therefore becomes PID 1 without receiving unsupported container arguments. During Android `early-init`, `royd-display-bootstrap` publishes the validated values as `vendor.royd.display.*` properties before the graphics setup runs. The royd allocator consumes those properties when the virtual framebuffer is opened.

This removes the previous post-boot `wm` and settings mutation path. Display size, density metadata, and frame-rate metadata are now established before SurfaceFlinger starts.

## Root filesystem packaging

The runtime archive is produced from royd's AOSP build output rather than from a conventional Dockerfile. The package step extracts AOSP's generated ramdisk as the OCI root, then mounts Android partition images read-only and merges their contents into one OCI root filesystem:

```text
ramdisk.img      -> /
system.img       -> /system
vendor.img       -> /vendor
system_ext.img   -> /system_ext, when present
product.img      -> /product, when present
odm.img          -> /odm, when present
```

Sparse Android images are converted with AOSP's `simg2img` before mounting.

The imported image uses `/royd-entrypoint` as the OCI entrypoint. It consumes only royd runtime arguments, writes the validated runtime configuration, then replaces itself with `/init` using `exec`. This keeps Android init as PID 1 while avoiding reliance on kernel-style `androidboot.*` command-line transport inside a container.

Display defaults are stored as the OCI image command so normal Docker arguments can replace them.

## Current limitation

Removing the previous external integration deliberately resets some assumptions that had not been independently validated. The repository now owns its dependency boundary, Binder setup, product definitions, packaging, and runtime arguments, but a full graphical boot from this independent AOSP baseline still needs to be proven on a reference host. The roadmap treats that validation as the next gate rather than claiming compatibility inherited from another project.

## OCI image identity

royd assigns canonical image tags from the pinned AOSP release, Android image profile, HAL profile, and CPU architecture. Development aliases are added separately so local workflows stay short while published or cached images remain unambiguous.

Every packaged root filesystem contains `/royd-release`. The package step also writes a sidecar manifest with the archive SHA-256 digest. Import refuses archives whose digest no longer matches the manifest.

Imported images carry OCI metadata plus royd labels for image format, Android source ref, architecture, and image profile. `runtime/scripts/image-inspect.sh` verifies this contract without booting Android.

## Host GPU runtime

Host GPU images are experimental and require `/dev/dri` to be passed into the container. Set `ROYD_GRAPHICS_BACKEND=host-gpu-generic` or `host-gpu-intel`; Compose adds the GPU device overlay automatically. Direct runtime scripts use `runtime/scripts/gpu-args.sh`. Software mode does not request a GPU device.
