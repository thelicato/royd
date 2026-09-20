# Android versions

royd keeps one repository-owned Android integration layer and applies it to a small set of pinned AOSP releases.

## Version matrix

| Android | Pinned AOSP tag | Lunch style | Status |
| --- | --- | --- | --- |
| 14 | `android-14.0.0_r14` | legacy product/variant | configured |
| 15 | `android-15.0.0_r36` | `bp1a` release config | baseline |
| 16 | `android-16.0.0_r4` | `bp4a` release config | configured |
| 17 | `android-17.0.0_r1` | `cp2a` release config | configured |

`baseline` means this is the default version used by the repository. `configured` means the version has pinned source and build metadata, but a clean royd build and container boot still need to be recorded before it is considered validated.

## Selecting a version

Android 15 remains the default:

```sh
make android-sync
make android-config-check
make android-build-x86_64
```

Other versions can be selected through `ROYD_ANDROID_VERSION`:

```sh
ROYD_ANDROID_VERSION=16 make android-sync
ROYD_ANDROID_VERSION=16 make android-config-check
ROYD_ANDROID_VERSION=16 make android-build-x86_64
```

Convenience targets are also provided:

```sh
make android-sync-14
make android-config-check-14
make android-build-x86_64-14
make android-package-x86_64-14
make runtime-import-x86_64-14
```

Replace `14` with `15`, `16`, or `17`, and `x86_64` with `arm64` where appropriate.

## Isolation

Each Android version uses separate local artefacts:

```text
.work/android-src-14
.work/android-src-15
.work/android-src-16
.work/android-src-17
.work/runtime/android-14
.work/runtime/android-15
.work/runtime/android-16
.work/runtime/android-17
```

Resolved manifests are also versioned. This prevents switching releases from silently reusing another version's source tree or runtime archive.

## Image tags

Canonical OCI tags include the pinned AOSP release, profile, and architecture. Development aliases include the Android version when it is not the default.

Examples:

```text
royd:14.0.0-r14-standard-amd64
royd:15.0.0-r36-standard-amd64
royd:16.0.0-r4-standard-amd64
royd:17.0.0-r1-standard-amd64

royd:dev
royd:dev-14
royd:dev-16
royd:dev-17
```

The Android version is embedded in `/royd-release` and in the `org.royd.android-version` OCI label.

## Compatibility policy

Do not assume repository-owned Android integration works unchanged across releases merely because the product configuration parses. Every supported version must eventually pass:

1. the static version matrix test
2. the resolved AOSP configuration preflight
3. a clean x86_64 build
4. a clean arm64 build
5. OCI packaging and image inspection
6. single-instance boot validation
7. multi-instance Binder isolation validation
8. the memory and security benchmark workflows

Version-specific patches, when needed, must remain in this repository under `android/patches/<AOSP tag>/`.
