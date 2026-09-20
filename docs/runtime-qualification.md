# Runtime qualification

Runtime qualification turns a built and imported royd image into persistent runtime evidence. It is intended for dedicated Linux validation hosts after clean-build and OCI packaging have succeeded.

A passing qualification is stronger than the normal smoke test, but it is still not by itself a support claim.

## Run the gate

For the default Android 15 x86_64 standard graphical image:

```sh
make runtime-qualification
```

The gate uses the same environment selectors as the build and runtime tooling. For example:

```sh
ROYD_ANDROID_VERSION=16 \
ROYD_QUALIFY_ARCH=arm64 \
ROYD_ANDROID_PROFILE=minimal \
ROYD_HAL_PROFILE=headless \
ROYD_SECURITY_MODE=privileged \
make runtime-qualification
```

The selected image must already exist in Docker. By default the gate resolves the normal royd development alias for the selected tuple. Set `ROYD_IMAGE` to test another tag explicitly.

Host ADB is required by default. Set `ROYD_QUALIFY_REQUIRE_ADB=0` only when collecting partial diagnostic evidence. An ADB-skipped result must not be used as complete runtime qualification.

## Evidence collected

The gate records these stages independently:

1. host contract preflight
2. OCI image contract inspection
3. selected security-mode inspection
4. configured and kernel-visible security evidence
5. Android boot completion
6. Docker health check
7. royd runtime assertions
8. container logcat forwarding
9. SurfaceFlinger service and `dumpsys SurfaceFlinger`
10. host-side ADB connectivity and `adb logcat`
11. full timestamped container logs plus Docker inspect and state evidence
12. two-container Binder isolation

The Binder isolation stage starts two disposable Android containers and compares the kernel character-device identities returned by the repository-owned `royd-binder-info` helper. Each private binderfs mount must expose different `binder-control`, `binder`, `hwbinder`, and `vndbinder` device identities. Linux binderfs defines devices in separate binderfs instances as independent Binder contexts, so this gives royd a concrete runtime check that each container received a distinct private device set.

## Result files

Results are stored under:

```text
.work/runtime-results/<android>/<arch>-<image-profile>-<hal-profile>-<security-mode>.env
.work/runtime-results/<android>/<arch>-<image-profile>-<hal-profile>-<security-mode>.log
.work/runtime-results/<android>/<arch>-<image-profile>-<hal-profile>-<security-mode>.evidence/
```

The result file records the selected image identity and each qualification stage. Security evidence includes the versioned security-profile ID and digest, Docker privilege/capability settings, active AppArmor profile when available, and Android PID 1 capability, `NoNewPrivs`, and seccomp state. The log contains detailed stage output. The companion evidence directory persists `container.log` from full timestamped `docker logs`, `container-inspect.json`, and `state.txt` before the qualification container is removed. This makes boot-watchdog and early-init diagnostics reviewable after a failed run.

Qualify several already-imported images with the resumable matrix runner:

```sh
ROYD_QUALIFY_VERSIONS="14 15 16" \
ROYD_QUALIFY_ARCHES="x86_64 arm64" \
make runtime-qualification-matrix
```

Passing tuples are skipped on later runs unless `ROYD_QUALIFY_RESUME=0` is set. The matrix retains failures and returns non-zero if any selected tuple fails.

Generate a table for all configured Android versions with:

```sh
make runtime-qualification-report
```

Write it to a file with:

```sh
ROYD_RUNTIME_REPORT_OUTPUT=runtime-qualification.md \
make runtime-qualification-report
```

## Compatibility matrix integration

`make android-matrix-report` consumes matching runtime result files and adds a Runtime column. A passing result changes that tuple's evidence state to `runtime-qualified`.

A validation host can require runtime evidence explicitly:

```sh
ROYD_MATRIX_REQUIRE_RUNTIME=1 make android-matrix-report
```

This does not promote the tuple to supported. The support policy also requires reviewed memory evidence and a documented reference-host result.

## Disposable state

Qualification containers and `/data` volumes are disposable and removed when the test exits. The runner publishes ADB on an automatically selected loopback port, so it can coexist with other local Android instances without assuming port 5555 is free.

## Policy provenance

Runtime qualification results use result format 4. They record `PROFILE_POLICY` plus `PROFILE_POLICY_SHA256`, and `SECURITY_PROFILE` plus `SECURITY_PROFILE_SHA256`. Result format 4 also requires successful persisted container-evidence capture for a passing qualification. Resume mode accepts previous evidence only when both policy identities still match the repository. Package-policy or security-policy changes therefore invalidate stale runtime qualification automatically.
