# Continuous integration

royd separates lightweight repository CI from expensive AOSP validation.

## Lightweight CI

Run the same checks used by the hosted workflow with:

```sh
make ci
```

This covers repository rules, runtime contracts, the Android version matrix, builder families, image and HAL profiles, mocked AOSP configuration resolution, legacy memory compatibility, graphics and HAL contracts, OCI image metadata, security, ADB, runtime qualification contracts and matrix-runner behaviour, and Go CLI tests.

It does not download or compile AOSP.

## Android compatibility matrix

Generate a Markdown matrix with:

```sh
make android-matrix-report
```

Write it to a file with:

```sh
ROYD_MATRIX_OUTPUT=android-matrix.md make android-matrix-report
```

For each Android version and architecture, the report records source-tree presence, resolved AOSP configuration, clean-build evidence, package evidence, and matching persisted runtime qualification evidence when available.

Missing source trees are informational by default. On a dedicated AOSP validation host, require every source tree and resolved configuration to pass with:

```sh
ROYD_MATRIX_STRICT=1 make android-matrix-report
```

Strict mode is intended for machines that have already synchronised every version under `.work/android-src-<version>`. `ROYD_MATRIX_REQUIRE_BUILD=1` additionally requires clean-build evidence, while `ROYD_MATRIX_REQUIRE_RUNTIME=1` requires a passing runtime qualification result for the selected security mode.

## Full validation

A successful lightweight CI run is not evidence that Android builds or boots. Full release validation still requires clean x86_64 and arm64 builds, OCI packaging, image inspection, real container boots, Binder isolation, graphics, ADB, memory, and security tests.
