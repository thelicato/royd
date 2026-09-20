# Building Android

## Baseline

The first royd runtime baseline is Android 15 using AOSP tag `android-15.0.0_r36` and ReDroid's Android 15 integration. This version was chosen because ReDroid publishes Android 15 images and its public patch repository contains a matching `android-15.0.0_r36` patch set.

The baseline values live in [`android/baseline.env`](../android/baseline.env). ReDroid's manifest branch is currently `15.0.0`. The patch repository is fetched from its configured ref and detached to the resolved commit during source setup. After synchronisation, royd writes `.work/android-manifest.lock.xml` with exact project revisions for diagnostics and reproducibility work.

This is an implementation baseline, not a permanent compatibility promise. Android 16 can be evaluated after the Android 15 container boot path is understood.

## Storage and memory

AOSP builds are large. Google currently recommends at least 400 GB of free disk space for an AOSP checkout and build, and at least 64 GB of RAM. royd uses those figures as the initial reference build-machine requirements. Lower-resource builders may work with reduced parallelism and swap, but are not part of the initial reference configuration.

All source and build output is kept below `.work/`, which is ignored by Git.

## Builder container

The repository provides a development builder container so the AOSP toolchain dependencies do not have to be installed directly on the host. Docker is used only for the build environment here. This is separate from the royd runtime image that will eventually run Android.

Open a builder shell with:

```sh
make android-shell
```

The scripts can also be called directly with `android/scripts/builder.sh`.

The repository and `.work` directory are mounted into the builder. The container runs as the invoking user's UID and GID so generated files remain writable on the host.

The builder currently uses Ubuntu 22.04 and downloads Google's `repo` launcher. It is intentionally a development aid rather than part of the runtime contract.

## Fetching sources

Synchronise the source tree with:

```sh
make android-sync
```

The script:

1. Initialises the pinned AOSP tag.
2. Adds the ReDroid Android 15 local manifest.
3. Synchronises AOSP and Git LFS content.
4. Fetches the ReDroid patch repository.
5. Applies the patch set matching the AOSP tag.
6. Writes a resolved manifest to `.work/android-manifest.lock.xml`.

The default source tree is `.work/android-src`. Set `ROYD_ANDROID_SRC` to use a different path. Set `JOBS` to limit parallel source synchronisation and compilation.

Source synchronisation is intentionally not run by repository checks because it downloads a very large external tree.

## Building

Build the x86_64 baseline with:

```sh
make android-build-x86_64
```

Or build arm64 with:

```sh
make android-build-arm64
```

For Android 15 the scripts use the AP3A release configuration and the ReDroid `userdebug` products. The resulting Android output remains inside the AOSP source tree under `out/`.

This task stops at producing the upstream-compatible Android build. Packaging the build into the first royd OCI runtime image, changing Binder ownership, and forwarding `logcat` to container output are subsequent milestones.

## Upstream references

- ReDroid documentation: <https://github.com/remote-android/redroid-doc>
- ReDroid local manifests: <https://github.com/remote-android/local_manifests>
- ReDroid patches: <https://github.com/remote-android/redroid-patches>
- AOSP build documentation: <https://source.android.com/docs/setup/build/building>
