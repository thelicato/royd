# Android versions

royd keeps one repository-owned Android integration layer and applies it to pinned AOSP releases from Android 8.1 through Android 17.

## Version matrix

| Android | Pinned AOSP tag | Build family | Partition family | Status |
| --- | --- | --- | --- | --- |
| 8.1 | `android-8.1.0_r81` | legacy | `system`, `vendor` | legacy-configured |
| 9 | `android-9.0.0_r61` | legacy | `system`, `vendor` | legacy-configured |
| 10 | `android-10.0.0_r47` | legacy | `system`, `vendor`, `product` | legacy-configured |
| 11 | `android-11.0.0_r48` | modern | `system`, `vendor`, `system_ext`, `product` | configured |
| 12 | `android-12.0.0_r34` | modern | `system`, `vendor`, `system_ext`, `product` | configured |
| 13 | `android-13.0.0_r75` | modern | `system`, `vendor`, `system_ext`, `product` | configured |
| 14 | `android-14.0.0_r14` | modern | `system`, `vendor`, `system_ext`, `product` | configured |
| 15 | `android-15.0.0_r36` | modern | `system`, `vendor`, `system_ext`, `product` | baseline |
| 16 | `android-16.0.0_r4` | modern | `system`, `vendor`, `system_ext`, `product` | configured |
| 17 | `android-17.0.0_r1` | modern | `system`, `vendor`, `system_ext`, `product` | configured |

`baseline` means the default version used by the repository. `configured` means source, build metadata, and the modern compatibility family are wired but clean build and boot evidence is still required. `legacy-configured` means the source, legacy builder, product family, and partition contract are wired, but additional compatibility work is expected before the release can boot on a modern host.

Android 8.0 is not currently pinned. The legacy support line begins at Android 8.1.

## Compatibility families

The repository does not force one modern product definition onto every release.

- `legacy` covers Android 8.1 and 9. It uses a Java 8/Python 2-capable builder and a two-partition OCI payload made from `system` and `vendor`.
- `transitional` covers Android 10. It uses the legacy builder but adds a separate `product` partition.
- `modern` covers Android 11 onward. It uses the current builder and the four-partition `system`, `vendor`, `system_ext`, and `product` contract.

The compatibility fragments live under [`../android/compat/`](../android/compat/). They are copied into the AOSP tree by the normal royd installation step.

## Legacy memory compatibility

Android 8.1 and 9 predate the modern Android move away from ashmem. Their matrix entries are explicitly marked `ashmem-compat-required`. royd will not require the removed host `ashmem_linux` module as its long-term solution. A repository-owned compatibility path backed by modern Linux memory primitives still needs to be implemented and validated.

Android 10 is marked `ashmem-transition` because it sits across that migration boundary. Android 11 onward is treated as `memfd-capable` in the royd matrix, subject to real build and runtime validation.

## Selecting a version

Android 15 remains the default:

```sh
make android-sync
make android-config-check
make android-build-x86_64
```

Other versions can be selected through `ROYD_ANDROID_VERSION`:

```sh
ROYD_ANDROID_VERSION=9 make android-sync
ROYD_ANDROID_VERSION=9 make android-config-check
ROYD_ANDROID_VERSION=9 make android-build-x86_64
```

Convenience targets work for every configured version:

```sh
make android-sync-8.1
make android-config-check-10
make android-build-x86_64-12
make android-package-arm64-13
make runtime-import-x86_64-17
```

## Build containers

`ANDROID_BUILDER_FAMILY` is release metadata, not a user-facing guess.

The modern builder is based on Ubuntu 22.04. The legacy builder is based on Ubuntu 18.04 and includes OpenJDK 8 plus Python 2 and Python 3 for older AOSP build systems.

Run:

```sh
make android-builder-family-test
```

to verify that older releases select the legacy builder and newer releases select the modern builder.

## Isolation

Each Android version uses separate local artefacts under `.work`, including source trees, resolved manifests, runtime archives, and profile stamps. Switching versions therefore cannot silently reuse another version's source tree or OCI archive.

## Image tags

Canonical OCI tags include the pinned AOSP release, profile, and architecture. Development aliases include the Android version when it is not the default.

Examples:

```text
royd:8.1.0-r81-standard-amd64
royd:10.0.0-r47-standard-amd64
royd:15.0.0-r36-standard-amd64
royd:17.0.0-r1-standard-arm64

royd:dev-8.1
royd:dev-10
royd:dev
royd:dev-17-arm64
```

The Android version, required partition set, and memory compatibility class are embedded in the runtime release metadata.

## Compatibility policy

Do not describe a version as supported merely because its product configuration parses. Every supported version must eventually pass:

1. the static version and builder-family tests
2. the resolved AOSP configuration preflight
3. a clean x86_64 build
4. a clean arm64 build
5. OCI packaging and image inspection
6. single-instance boot validation
7. multi-instance Binder isolation validation
8. graphics validation
9. memory and security benchmark workflows
10. any release-specific legacy memory compatibility tests

Version-specific patches, when needed, must remain in this repository under `android/patches/<AOSP tag>/`.
