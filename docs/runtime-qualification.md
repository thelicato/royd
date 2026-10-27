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

The stage retains both containers under `<result>.evidence/binder-isolation/`: format-1 `manifest.env`, separate boot/runtime outputs, raw device identities when reached, and `a/`/`b/` full timestamped logs, inspect and state. Copy available `/data/anr` watchdog/thread dumps before removing their disposable volumes; an unavailable directory probe is recorded, not evidence of no ANR. Capture precedes deletion even on failure or interruption. A failed capture or changed ownership fails the gate and leaves the affected resources for inspection; the manifest records capture/cleanup separately from runtime/identity. Existing names, volumes and evidence are never adopted or replaced. Standalone `make runtime-binder-isolation-test` generates a fresh `.work/binder-isolation-<timestamp>-<pid>` directory; set `ROYD_BINDER_OUTPUT_DIR` to select another new directory.

## Result files

Results are stored under:

```text
.work/runtime-results/<android>/<arch>-<image-profile>-<hal-profile>-<security-mode>.env
.work/runtime-results/<android>/<arch>-<image-profile>-<hal-profile>-<security-mode>.log
.work/runtime-results/<android>/<arch>-<image-profile>-<hal-profile>-<security-mode>.evidence/
```

The result file records the selected image identity and each qualification stage. Security evidence includes the versioned security-profile ID and digest, Docker privilege/capability settings, active AppArmor profile when available, and Android PID 1 capability, `NoNewPrivs`, and seccomp state. The log contains detailed stage output. The companion evidence directory persists `container.log` from full timestamped `docker logs`, `container-inspect.json`, and `state.txt` before the qualification container is removed. This makes boot-watchdog and early-init diagnostics reviewable after a failed run.

When a Binder companion directory already exists, qualification refuses reuse before opening the previous result or log. Select a fresh `ROYD_RUNTIME_RESULT_FILE` (or fresh results directory for a matrix rerun) to retain earlier attempts.

Task155's rebuilt image `79568439e907` passes one full evidenced qualification after an earlier companion pre-watchdog failure. Five-minute scrcpy, global callbacks and bridge-DNS native/WebView HTTPS also pass locally. A later embedded-DNS run fails before workload on another startup pre-watchdog, this time with only one instance. Its retained log shows startup continuing and `StartServices` taking 33.746 seconds, but its TLS cleanup lost the thread dump. Keep the failed qualification and failed TLS manifest independently; neither a healthy eventual boot nor a later pass explains the wait. Watchdog diagnosis and that mode's new-image HTTPS witness remain open, separately from the Binder capture correction.

Docker can omit health state for a never-started container or an image without a health check. The collector records `health=none` and still captures logs/inspect; an empty log is valid only when `docker logs` succeeds. Present `starting`/`unhealthy` states and Docker errors remain visible, and unavailable inspect/log commands still fail capture. Evidence capture is not boot or health qualification: a failed start remains failed. `make runtime-container-evidence-test` uses Go to execute the production template with strict missing-key checks, plus mocked collection failures; the collector itself requires only Docker and the shell.

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

Runtime qualification results use result format 4. They record `PROFILE_POLICY` plus `PROFILE_POLICY_SHA256`, `SECURITY_PROFILE` plus `SECURITY_PROFILE_SHA256`, and the selected `RESOURCE_PROFILE`. Result format 4 also requires successful persisted container-evidence capture for a passing qualification. Resume mode accepts previous evidence only when both policy identities still match the repository and the resource profile matches the requested mode. Package-policy, security-policy, or resource-profile changes therefore invalidate stale runtime qualification automatically.
