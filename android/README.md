# Android runtime

This directory contains everything royd adds to the pinned AOSP source tree.

The baseline is AOSP `android-15.0.0_r36`. Baseline values are kept in [`baseline.env`](baseline.env), and the build workflow is documented in [`../docs/building.md`](../docs/building.md).

royd does not fetch an external Android device tree, vendor tree, local manifest, or patch repository. Source synchronisation fetches only the pinned AOSP manifest. Repository-owned product definitions are copied from [`royd/device/royd`](royd/device/royd), repository-owned vendor integration is copied from [`royd/vendor/royd`](royd/vendor/royd), and any required AOSP source patches must be committed under [`patches`](patches).

The initial royd products inherit AOSP's generic x86_64 and arm64 products to provide a buildable baseline while the container-specific hardware surface is implemented and validated independently.

Do not add runtime debloating scripts as a substitute for product-level Android configuration. Features intentionally omitted from an image profile should normally be removed or disabled through Android build configuration where practical.

## Image profiles

royd currently provides `standard` and `minimal` Android image profiles under [`profiles`](profiles). The standard profile preserves the inherited AOSP package set. The minimal profile removes a small, explicit set of optional packages for comparative measurement.

Use the normal build targets for standard images and the `*-minimal-*` targets for the minimal image. See [`../docs/image-profiles.md`](../docs/image-profiles.md) for details.
