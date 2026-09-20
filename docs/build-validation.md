# Build validation

royd separates source configuration, clean compilation, OCI packaging, and runtime support into different validation gates. A passing build is evidence that the Android product compiled, not evidence that the resulting container is supported.

## Clean-build matrix

The clean-build runner executes the selected stages for each Android version and architecture:

```sh
make android-build-matrix
```

By default it targets Android 8.0 through 17, both `x86_64` and `arm64`, the `standard` image profile, and the `graphical` HAL profile. It expects the corresponding version-specific AOSP source trees to exist under `.work`.

Each tuple runs:

1. resolved AOSP configuration validation
2. a clean Android build
3. OCI root filesystem packaging

A clean build removes that source tree's `out` directory before compilation. This is intentionally expensive and should normally run on dedicated build hosts rather than lightweight CI.

## Selecting the matrix

Environment variables can narrow or change the run:

```sh
ROYD_BUILD_VERSIONS="14 15 16" \
ROYD_BUILD_ARCHES="x86_64" \
make android-build-matrix
```

Available controls include:

- `ROYD_BUILD_VERSIONS`: space-separated Android versions
- `ROYD_BUILD_ARCHES`: `x86_64`, `arm64`, or both
- `ROYD_ANDROID_PROFILE`: `standard` or `minimal`
- `ROYD_HAL_PROFILE`: `graphical` or `headless`
- `ROYD_BUILD_STAGES`: any ordered subset of `config build package`
- `ROYD_BUILD_CLEAN`: `1` by default, remove AOSP `out` before each build
- `ROYD_BUILD_SYNC`: set to `1` to synchronise a missing source tree before validation
- `ROYD_BUILD_RESUME`: `1` by default, skip tuples already recorded as passing
- `ROYD_BUILD_CONTINUE_ON_ERROR`: `1` by default, continue collecting failures
- `ROYD_BUILD_RESULTS_DIR`: override the generated result directory
- `ROYD_BUILD_REPORT_OUTPUT`: override the generated Markdown report path

Automatic source synchronisation is disabled by default because checking out every pinned AOSP version is very large and should be an explicit operator decision.

## Result records

Generated evidence is stored under:

```text
.work/build-results/<android>/<arch>-<image-profile>-<hal-profile>.env
.work/build-results/<android>/<arch>-<image-profile>-<hal-profile>.log
```

The environment-style result file records:

- Android version and pinned AOSP tag
- architecture
- image and HAL profiles
- whether clean mode was enabled and which stages were requested
- source synchronisation state when the runner was asked to sync missing trees
- config, build, and package stage results
- overall result
- SHA-256 of the resolved AOSP manifest lock when available
- packaged archive SHA-256 when packaging succeeds
- start and finish timestamps

These files are generated evidence and are not committed to the repository.

## Resuming a build host

Successful tuples are skipped by default on later runs. Failed or missing tuples are retried:

```sh
make android-build-matrix
```

Set `ROYD_BUILD_RESUME=0` to force every selected tuple to run again.

## Reports

Render existing build evidence without compiling anything:

```sh
make android-build-results-report
```

The normal compatibility matrix also consumes the default `standard` and `graphical` build evidence when it exists:

```sh
make android-matrix-report
```

Use:

```sh
ROYD_MATRIX_REQUIRE_BUILD=1 make android-matrix-report
```

to make missing or failed clean-build evidence fatal. This is intended for dedicated validation hosts, not lightweight CI.

## Builder TTY behaviour

The builder no longer assumes an interactive terminal. `ROYD_BUILDER_TTY=auto` is the default and allocates `-it` only when stdin and stdout are terminals. Dedicated CI can explicitly set:

```sh
ROYD_BUILDER_TTY=never
```

Interactive debugging can force a terminal with `ROYD_BUILDER_TTY=always`.

## Support status

Build evidence is only one release gate. A version should not be called supported until it also passes OCI import, Android boot, Binder isolation, graphics, ADB, memory, and security validation on documented hosts.

## Image-profile policy provenance

Build results use result format 2 and record `PROFILE_POLICY` plus `PROFILE_POLICY_SHA256`. Resume mode skips a passing tuple only when those values still match the repository policy for that Android version. Changing the minimal package manifest therefore forces the tuple to run again instead of reusing stale build evidence.
