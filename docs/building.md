# Building Android

## Baseline

royd currently targets AOSP `android-15.0.0_r36`. The source baseline is intentionally plain AOSP. No third-party Android manifest, device tree, vendor tree, or patch repository is fetched by the build.

The baseline values live in [`android/baseline.env`](../android/baseline.env). After synchronisation, royd writes `.work/android-manifest.lock.xml` with exact AOSP project revisions for diagnostics and reproducibility work.

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
3. Applies any repository-owned patches under `android/patches/android-15.0.0_r36`.
4. Copies the repository-owned `device/royd` and `vendor/royd` projects into the source tree.
5. Writes a resolved manifest to `.work/android-manifest.lock.xml`.

The default source tree is `.work/android-src`. Set `ROYD_ANDROID_SRC` to use a different path. Set `JOBS` to limit source synchronisation and compilation.

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
