# Android runtime

This directory contains the Android source baseline and build tooling used to create the royd runtime.

The initial baseline is AOSP `android-15.0.0_r36` with ReDroid's Android 15 integration. Baseline values are kept in [`baseline.env`](baseline.env), and the build workflow is documented in [`../docs/building.md`](../docs/building.md).

The implementation stays close to upstream ReDroid while adding a small royd vendor layer. Source synchronisation installs this layer after the upstream ReDroid patches so binderfs startup, container logging, and later low-memory changes remain clearly separated from upstream code.

Do not add runtime debloating scripts as a substitute for product-level Android configuration. Features intentionally omitted from an image profile should normally be removed or disabled through Android build configuration where practical.

The royd-specific Android files live under [`royd/vendor/royd`](royd/vendor/royd). Runtime packaging and execution are documented in [`../runtime/README.md`](../runtime/README.md).
