# Android image profiles

royd separates Android image profiles from runtime display profiles. Android image profiles change what is built into Android and require a rebuild. Runtime display profiles only change width, height, density, and frame rate at container start.

## `standard`

The standard profile keeps the inherited AOSP package set intact while applying royd's low-RAM properties and container integration. It is the compatibility baseline and produces the default local image tag `royd:dev`.

Build and import it with:

```sh
make android-build-x86_64
make android-package-x86_64
make runtime-import-x86_64
```

Its package policy is identified as `standard-v1` and has an empty removal manifest.

## `minimal`

The minimal profile removes optional handheld applications while deliberately protecting Android components needed for the declared royd runtime contract. The removal policy is version-family aware because the AOSP handheld product composition changes between legacy, transitional, and modern Android releases.

Packages removed from every family where present are:

```text
BasicDreams
EasterEgg
PrintRecommendationService
PrintSpooler
```

Android 8.0 through 9 additionally remove:

```text
Browser2
Calendar
Contacts
DeskClock
Email
QuickSearchBox
```

Android 10 additionally removes:

```text
Browser2
Calendar
Camera2
Contacts
DeskClock
Email
Gallery2
Music
QuickSearchBox
```

Android 11 onward additionally removes:

```text
Browser2
Calendar
Camera2
Contacts
DeskClock
Email
Gallery2
Music
PhotoTable
QuickSearchBox
```

Missing package names are harmless because the product makefile filters only packages actually selected by the upstream product. The policy intentionally keeps core UI, Settings, package management, storage, networking, input, ADB, SystemUI, and the launcher path. `android/profiles/protected.packages` is a regression guard: a protected package cannot enter the minimal removal policy without the profile contract test failing.

Build and import it with:

```sh
make android-build-minimal-x86_64
make android-package-minimal-x86_64
make runtime-import-minimal-x86_64
```

The default local tag is `royd:dev-minimal`.

## Policy identity

`install-royd.sh` resolves the family-specific package manifest into `vendor/royd/profile-packages.txt`. The resulting image installs the same list as `/vendor/etc/royd-profile-packages.txt` and exposes both a policy identifier and the SHA-256 of that exact list.

For example, a modern minimal image uses:

```text
ro.vendor.royd.profile_policy=minimal-v2-modern
ro.vendor.royd.profile_policy_sha256=<sha256>
```

The same values are recorded in `/royd-release` and the OCI labels `org.royd.profile-policy` and `org.royd.profile-policy-sha256`. Changing the policy digest also changes the Android build stamp, which forces `installclean` before the next build for that version and architecture.

Validate the repository policy with:

```sh
make android-profile-policy-test
```

## Switching profiles

The selected profile is installed into `vendor/royd/profile.mk` before each Android build. If the image profile, package policy revision or digest, HAL profile, or graphics backend changes for the same architecture, the build script runs AOSP `installclean` before rebuilding. This reduces the risk of stale installed files contaminating profile comparisons.

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

The comparison runs the same candidate memory limits and runtime display profile against each Android image profile, records Docker image size, and includes the package count observed after boot. Each embedded memory report also records the exact profile-policy digest and workload, so measurements remain attributable if the minimal package set changes later.

The current expanded minimal policy still requires clean-build and representative workload validation before any support or memory claim is made. Further removals should be proposed only with comparable runtime evidence.
