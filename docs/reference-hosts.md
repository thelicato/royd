# Reference-host reports

royd compatibility claims should be backed by reports collected from real hosts rather than inferred from distribution names alone.

## Collecting a report

Build and import the image first, then run:

```sh
make runtime-reference-report
```

The report is written to stdout. To save it directly:

```sh
ROYD_REPORT_OUTPUT=reference-host.md make runtime-reference-report
```

To test another image:

```sh
ROYD_IMAGE=example/royd:test ROYD_REPORT_OUTPUT=reference-host.md make runtime-reference-report
```

The command runs both the single-instance and two-instance smoke tests and exits non-zero if either fails. The report is still written when a smoke test fails so that the failure evidence is preserved.

## Recorded data

The report includes:

- royd commit when the repository is a Git checkout
- pinned Android baseline
- image name
- host distribution
- kernel and architecture
- CPU and total RAM
- cgroup mode
- binderfs availability
- `/dev/dri` presence
- relevant kernel configuration when readable
- Docker version and Docker info
- complete single-instance smoke-test output
- complete two-instance smoke-test output

A report demonstrates behaviour only for the exact environment it records. It does not establish support for every host using the same distribution or kernel family.

## Qualification evidence bundle

For support-oriented validation, prefer the higher-level bundle workflow after the image has been built and imported:

```sh
make runtime-reference-qualify
```

By default the bundle is written under `.work/reference-hosts/` and includes the host check, OCI image inspection, persisted runtime qualification result, reference-host report, memory sweep, orchestration log, a versioned `manifest.env`, and `SHA256SUMS`. The default bundle deliberately does not run the expensive experimental capability-removal sweep. Enable that only while qualifying the experimental security mode:

```sh
ROYD_SECURITY_MODE=experimental \
ROYD_REFERENCE_INCLUDE_CAPABILITY_SWEEP=1 \
make runtime-reference-qualify
```

Use a dedicated output directory when the evidence will be retained or reviewed:

```sh
ROYD_REFERENCE_BUNDLE_OUTPUT=evidence/15-x86_64-standard \
make runtime-reference-qualify
```

The output directory is immutable by default. Set `ROYD_REFERENCE_REPLACE=1` only when intentionally replacing local evidence.

Verify a collected bundle with:

```sh
make runtime-reference-bundle-verify BUNDLE=evidence/15-x86_64-standard
```

Verification checks every file listed in `SHA256SUMS`, requires the mandatory host/image/runtime/reference stages to have passed, requires the persisted runtime result, and compares the recorded image-profile and security-policy identities with the current repository. A changed minimal-package policy or security policy therefore makes old evidence stale instead of silently reusable.

A verified bundle is still evidence for one exact tuple and host. It is not by itself a support declaration. The support review must also confirm that the Android build evidence corresponds to the same image and that any published workload or hardware claims are represented by the collected evidence.

## Memory measurements

Reference-host reports establish runtime compatibility, not minimum RAM requirements. Memory measurements should continue to use the separate workflow in [`low-memory.md`](low-memory.md), including an exact workload, memory limit, display profile, graphics mode, and settling time.
