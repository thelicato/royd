# Android runtime

This directory contains the Android source baseline and build tooling used to create the royd runtime.

The initial baseline is AOSP `android-15.0.0_r36` with ReDroid's Android 15 integration. Baseline values are kept in [`baseline.env`](baseline.env), and the build workflow is documented in [`../docs/building.md`](../docs/building.md).

The first implementation deliberately stays close to upstream ReDroid. The order of work is to produce a known Android build, package and boot it as an OCI image, then introduce royd-specific Binder ownership, container logging, and low-memory changes incrementally.

Do not add runtime debloating scripts as a substitute for product-level Android configuration. Features intentionally omitted from an image profile should normally be removed or disabled through Android build configuration where practical.
