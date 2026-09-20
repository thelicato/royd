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

## Memory measurements

Reference-host reports establish runtime compatibility, not minimum RAM requirements. Memory measurements should continue to use the separate workflow in [`low-memory.md`](low-memory.md), including an exact workload, memory limit, display profile, graphics mode, and settling time.
