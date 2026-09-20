# Building Android

## Android version selection

Android 15 is the default build baseline. Android 14, 16, and 17 are also pinned and use the same repository-owned product integration. Use `ROYD_ANDROID_VERSION=<version>` or the version-suffixed Make targets. Each version has a separate source tree under `.work`.

See [`android-versions.md`](android-versions.md) for the complete matrix and validation status.

## Baseline

royd currently carries pinned AOSP configurations for Android 14, 15, 16, and 17. Android 15 is the default baseline. The source baseline is intentionally plain AOSP. No third-party Android manifest, device tree, vendor tree, or patch repository is fetched by the build.

Shared defaults live in [`android/baseline.env`](../android/baseline.env), with release-specific values under [`android/versions/`](../android/versions/). After synchronisation, royd writes `.work/android-manifest-<version>.lock.xml` with exact AOSP project revisions for diagnostics and reproducibility work.

All royd-specific Android integration is stored in this repository:

- `android/royd/device/royd` contains the royd product definitions.
- `android/royd/vendor/royd` contains init integration, Binder allocation, logging, display setup, and low-memory properties.
- `android/profiles` contains build-time image profiles.
- `android/patches/<AOSP tag>` is reserved for source patches that cannot be expressed as product or vendor configuration.

This is an implementation baseline, not a permanent Android-version compatibility promise.

## Storage and memory

AOSP builds are large. Google currently recommends at least 400 GB of free disk space for an AOSP checkout and build, and at least 64 GB of RAM. royd uses those figures as the initial reference build-machine requirements. Lower-resource builders may work with reduced parallelism and swap, but are not part of the initial reference configuration.

All source and build output is kept below `.work/`, which is ignored by Git.

## Builder container

The repository provides a development builder container so AOSP toolchain dependencies do not have to be installed directly on the host.

Open a builder shell with:

```sh
make android-shell
```

The repository and `.work` directory are mounted into the builder. The container runs as the invoking user's UID and GID so generated files remain writable on the host.

## Fetching sources

Synchronise the source tree with:

```sh
make android-sync
```

The script:

1. Initialises the pinned AOSP tag.
2. Synchronises AOSP and Git LFS content.
3. Applies any repository-owned patches under `android/patches/<AOSP tag>` when that release needs local changes.
4. Copies the repository-owned `device/royd` and `vendor/royd` projects into the source tree.
5. Writes a resolved manifest to `.work/android-manifest-<version>.lock.xml`.

The default source tree is `.work/android-src-<version>`. Set `ROYD_ANDROID_SRC` to use a different path. Set `JOBS` to limit source synchronisation and compilation.

## Preflight build contract

Before a full compile, royd can validate the static repository contract and the resolved AOSP product configuration.

Run the repository-only contract test at any time:

```sh
make android-contract-test
make android-config-check-test
```

After synchronising AOSP, run:

```sh
make android-config-check
```

The AOSP-backed preflight installs the royd product definitions, selects both lunch targets, and checks the resolved product, device, architecture, no-kernel/no-bootloader settings, filesystem types, and partition copy-out paths against [`android/build-contract.env`](../android/build-contract.env). It performs product configuration but does not compile Android.

The current packaging contract requires separate ext4 images for `system`, `vendor`, `system_ext`, and `product`. The board configuration overrides GSI placement defaults where necessary, and `PRODUCT_USE_DYNAMIC_PARTITION_SIZE` lets the build size those images from their contents rather than from a virtual flash layout. The packager treats all four images as required.

## Building

Build the x86_64 baseline with:

```sh
make android-build-x86_64
```

Or build arm64 with:

```sh
make android-build-arm64
```

The build uses royd's own `royd_x86_64` and `royd_arm64` products with the Android 15 BP1A release configuration and `userdebug` variant. Those products inherit AOSP generic products as the current hardware baseline, then layer royd-owned container integration on top.

After a successful build, package and import the development runtime with:

```sh
make android-package-x86_64
make runtime-import-x86_64
```

The package step extracts the generated Android ramdisk with its recorded ownership and modes, then adds system and vendor plus system_ext, product, and odm images when present. Android sparse images are converted using the AOSP-built `simg2img` tool before read-only mounting. The result is `.work/runtime/royd-<arch>-<profile>.tar`.

## Dependency policy

The only Android source dependency in the normal build path is the pinned AOSP manifest. Any new royd-specific device code, vendor code, helper binary, init configuration, or AOSP patch must be added to this repository rather than fetched from another Android container project.

See [`acknowledgements.md`](acknowledgements.md) for projects that influenced the design.

## Upstream reference

- AOSP build documentation: <https://source.android.com/docs/setup/build/building>
