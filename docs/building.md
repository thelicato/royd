# Building Android

## Android version selection

Android 15 is the default build baseline. Pinned configurations span Android 8.0 through 17. Use `ROYD_ANDROID_VERSION=<version>` or the version-suffixed Make targets. Each version has a separate source tree under `.work`, and Android 8.0 through 10 select the legacy builder automatically.

See [`android-versions.md`](android-versions.md) for the complete matrix and validation status.

## Baseline

royd carries pinned AOSP configurations for Android 8.0 through 17. Android 15 is the default baseline. The source baseline is intentionally plain AOSP. No third-party Android manifest, device tree, vendor tree, or patch repository is fetched by the build.

Shared defaults live in [`android/baseline.env`](../android/baseline.env), with release-specific values under [`android/versions/`](../android/versions/). After synchronisation, royd writes `.work/android-manifest-<version>.lock.xml` with exact AOSP project revisions for diagnostics and reproducibility work.

All royd-specific Android integration is stored in this repository:

- `android/royd/device/royd` contains the royd product definitions.
- `android/royd/vendor/royd` contains init integration, Binder allocation, logging, display setup, and low-memory properties.
- `android/profiles` contains build-time image profiles.
- `android/compat` contains version-family product, board, and vendor fragments for legacy, transitional, and modern Android releases.
- `android/patches/<AOSP tag>` is reserved for source patches that cannot be expressed as product or vendor configuration.

This is an implementation baseline, not a permanent Android-version compatibility promise.

## Storage and memory

AOSP builds are large. Google currently recommends at least 400 GB of free disk space for an AOSP checkout and build, and at least 64 GB of RAM. royd uses those figures as the initial reference build-machine requirements. Lower-resource builders may work with reduced parallelism and swap, but are not part of the initial reference configuration.

All source and build output is kept below `.work/`, which is ignored by Git.

## Builder container

The repository provides two development builder containers so AOSP toolchain dependencies do not have to be installed directly on the host. Android 8.0 through 10 use the Ubuntu 18.04/OpenJDK 8 legacy builder. Android 11 onward uses the modern Ubuntu 22.04 builder.

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
5. Installs the repository-owned memfd-backed `libcutils` compatibility backend for Android 8.0 through 10.
6. Writes a resolved manifest to `.work/android-manifest-<version>.lock.xml`.

The default source tree is `.work/android-src-<version>`. Set `ROYD_ANDROID_SRC` to use a different path. Set `JOBS` to limit source synchronisation and compilation.

## Preflight build contract

Before a full compile, royd can validate the static repository contract and the resolved AOSP product configuration.

Run the repository-only contract test at any time:

```sh
make android-contract-test
make android-memory-compat-test
make android-config-check-test
```

After synchronising AOSP, run:

```sh
make android-config-check
```

The AOSP-backed preflight installs the royd product definitions, selects both lunch targets, and checks the resolved product, device, architecture, no-kernel/no-bootloader settings, filesystem types, and partition copy-out paths against [`android/build-contract.env`](../android/build-contract.env). It performs product configuration but does not compile Android.

The packaging contract is version-aware. Android 8.0, 8.1, and 9 require `system` and `vendor`; Android 10 adds `product`; Android 11 onward requires `system`, `vendor`, `system_ext`, and `product`. The packager reads the required set from the selected version metadata.

## Building

Build the x86_64 baseline with:

```sh
make android-build-x86_64
```

Or build arm64 with:

```sh
make android-build-arm64
```

The build uses royd's own `royd_x86_64` and `royd_arm64` products with the selected release's lunch syntax and the `userdebug` variant. The installer selects a repository-owned compatibility fragment for that Android generation before AOSP resolves the product.

After a successful build, package and import the development runtime with:

```sh
make android-package-x86_64
make runtime-import-x86_64
```

The package step extracts the generated Android ramdisk with its recorded ownership and modes, then adds the exact partition set declared by the selected Android version plus optional partitions when present. Android sparse images are converted using the AOSP-built `simg2img` tool before read-only mounting. The result is `.work/runtime/royd-<arch>-<profile>.tar`.

## Dependency policy

The only Android source dependency in the normal build path is the pinned AOSP manifest. Any new royd-specific device code, vendor code, helper binary, init configuration, or AOSP patch must be added to this repository rather than fetched from another Android container project.

See [`acknowledgements.md`](acknowledgements.md) for projects that influenced the design.

## Upstream reference

- AOSP build documentation: <https://source.android.com/docs/setup/build/building>

## HAL profiles

The default build uses the `graphical` HAL profile. A headless-oriented server profile is also available. It keeps the minimum software graphics stack required for normal Android framework boot, but uses explicit headless identity and conservative optional hardware package removal.

```sh
make android-build-headless-x86_64
make android-package-headless-x86_64
make runtime-import-headless-x86_64
```

For version-specific builds, set `ROYD_HAL_PROFILE=headless` alongside `ROYD_ANDROID_VERSION`. See [`hal-profiles.md`](hal-profiles.md).
