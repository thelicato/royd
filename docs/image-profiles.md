# Android image profiles

royd separates Android image profiles from runtime display profiles. Android image profiles change what is built into Android and require a rebuild. Runtime display profiles only change width, height, density, and frame rate at container start.

## `standard`

The standard profile keeps the upstream ReDroid/AOSP package set intact while applying royd's low-RAM properties and container integration. It is the compatibility baseline and produces the default local image tag `royd:dev`.

Build and import it with:

```sh
make android-build-x86_64
make android-package-x86_64
make runtime-import-x86_64
```

## `minimal`

The minimal profile currently removes a deliberately small set of optional framework packages:

- `BasicDreams`
- `EasterEgg`
- `PrintRecommendationService`
- `PrintSpooler`

It intentionally keeps core UI, settings, package management, storage, networking, input, and ADB functionality. More packages should only be removed after runtime validation shows that the resulting image still satisfies its declared use cases.

Build and import it with:

```sh
make android-build-minimal-x86_64
make android-package-minimal-x86_64
make runtime-import-minimal-x86_64
```

The default local tag is `royd:dev-minimal`.

## Switching profiles

The selected profile is installed into `vendor/royd/profile.mk` before each Android build. If the build script detects a profile change for the same architecture, it runs AOSP `installclean` before rebuilding. This reduces the risk of stale installed files contaminating profile comparisons.

The built image exposes its profile through:

```sh
getprop ro.vendor.royd.image_profile
```

## Comparing profiles

After importing both images:

```sh
ROYD_IMAGE_PROFILE_SWEEP_OUTPUT=image-profile-sweep.md \
make image-profile-sweep
```

The comparison runs the same candidate memory limits and runtime display profile against each Android image profile, records Docker image size, and includes the package count observed after boot. This is intended to measure the effect of build-time slimming without turning one successful boot into a general support claim.
