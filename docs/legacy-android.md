# Legacy Android compatibility

Android 8.1, 9, and 10 require a different compatibility path from modern Android releases. royd keeps that path explicit instead of making the modern product layout silently conditional in many unrelated files.

## Build environment

Android 8.1 through 10 use `android/builder/Dockerfile.legacy`. It provides OpenJDK 8, Python 2, Python 3, and the older host dependencies required by those AOSP generations. Android 11 onward uses the modern builder.

## Partition layout

The OCI packager reads `ANDROID_REQUIRED_PARTITIONS` from each version definition.

- Android 8.1 and 9 require `system` and `vendor`.
- Android 10 requires `system`, `vendor`, and `product`.
- Android 11 onward requires `system`, `vendor`, `system_ext`, and `product`.

The board and product fragments under `android/compat` mirror those families.

## Binder

royd's Binder allocator carries the small binderfs userspace ABI definition it needs instead of depending on Android's exported kernel headers. This is intentional because Android 8.1 and 9 source trees predate binderfs headers even though a modern host kernel can provide binderfs to the container.

The Android framework continues to see `/dev/binder`, `/dev/hwbinder`, and `/dev/vndbinder` regardless of release.

## Shared memory

The largest known legacy blocker is ashmem-era userspace. Modern Linux removed the standalone ashmem driver, and royd does not want legacy Android support to require an out-of-tree host module.

The planned direction is a repository-owned compatibility layer that preserves the old Android userspace contract while using modern host memory primitives internally. Until that is implemented and tested, Android 8.1, 9, and 10 remain `legacy-configured` rather than supported.

## Validation order

Legacy releases should be validated in this order:

1. AOSP configuration preflight
2. clean build with the legacy builder
3. partition packaging
4. Binder bootstrap on a binderfs-only host
5. shared-memory compatibility
6. Android boot
7. graphics and ADB
8. memory and security benchmarking
