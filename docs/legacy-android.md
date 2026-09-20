# Legacy Android compatibility

Android 8.0, 8.1, 9, and 10 require a different compatibility path from modern Android releases. royd keeps that path explicit instead of making the modern product layout silently conditional in unrelated files.

## Build environment

Android 8.0 through 10 use `android/builder/Dockerfile.legacy`. It provides OpenJDK 8, Python 2, Python 3, and the older host dependencies required by those AOSP generations. Android 11 onward uses the modern builder.

## Partition layout

The OCI packager reads `ANDROID_REQUIRED_PARTITIONS` from each version definition.

- Android 8.0, 8.1, and 9 require `system` and `vendor`.
- Android 10 requires `system`, `vendor`, and `product`.
- Android 11 onward requires `system`, `vendor`, `system_ext`, and `product`.

The board and product fragments under `android/compat` mirror those families.

## Binder

royd's Binder allocator carries the small binderfs userspace ABI definition it needs instead of depending on Android's exported kernel headers. This is intentional because Android 8.0, 8.1, and 9 source trees predate binderfs headers even though a modern host kernel can provide binderfs to the container.

The Android framework continues to see `/dev/binder`, `/dev/hwbinder`, and `/dev/vndbinder` regardless of release.

## Shared memory

Android 8.0 through 10 normally expect the historical ashmem userspace API. royd does not require the removed `ashmem_linux` host module. During source preparation, these releases replace `system/core/libcutils/ashmem-dev.c` or `ashmem-dev.cpp` with the repository-owned implementation in `android/compat/memory/ashmem-dev.c`.

The compatibility backend preserves the `libcutils` ashmem function interface while creating sealed `memfd` regions on the modern host kernel. It implements region creation, size queries, protection changes, and the legacy pin/unpin calls without opening the historical ashmem device. A small `royd-memfd-probe` binary also checks at boot that the host supports memfd creation and sealing.

This is intentionally a userspace compatibility boundary, not a fake kernel device. Code that bypasses `libcutils` and issues ashmem-specific ioctls directly may still be incompatible. Older Android releases therefore remain `legacy-configured` until clean builds and representative application workloads prove that this boundary is sufficient.

Run the local compatibility checks with:

```sh
make android-memory-compat-test
```

## Validation order

Legacy releases should be validated in this order:

1. AOSP configuration preflight
2. clean build with the legacy builder
3. partition packaging
4. Binder bootstrap on a binderfs-only host
5. memfd-backed `libcutils` shared-memory validation
6. Android boot
7. representative framework and application shared-memory workloads
8. graphics and ADB
9. memory and security benchmarking
