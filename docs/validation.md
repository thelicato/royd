# Runtime validation

The runtime validation scripts are intended to turn host testing into a repeatable step before royd publishes compatibility or memory claims. They use Docker and commands already present inside Android, so ADB is not required.

## Single-instance smoke test

Build, package, and import `royd:dev`, then run:

```sh
make runtime-smoke-test
```

The test creates a temporary Docker volume and privileged container, waits for `sys.boot_completed=1`, then checks:

- Android completed boot.
- `/dev/binder`, `/dev/hwbinder`, and `/dev/vndbinder` are character devices.
- binderfs is mounted at `/dev/binderfs`.
- the royd binderfs readiness message reached container logs.
- `ro.config.low_ram` is enabled.
- the royd logcat forwarding service is running.

The temporary container and volume are removed when the test exits, including after failure.

## Two-instance smoke test

Run:

```sh
make runtime-multi-test
```

This starts two containers at the same time with separate `/data` volumes, waits for both to boot, and applies the same runtime assertions to each instance. It confirms that both containers can create and use their own binderfs mounts concurrently. It does not by itself prove that Binder IPC cannot cross between the two Binder contexts, so cross-context isolation remains a separate validation item.

For manual testing with ADB, the repository also provides:

```sh
docker compose -f runtime/compose.multi.yaml up -d
```

The two instances expose ADB on `127.0.0.1:5555` and `127.0.0.1:5556`.

## Timeouts and image selection

The default boot timeout is 180 seconds. Override it when testing slower hosts:

```sh
ROYD_BOOT_TIMEOUT=300 make runtime-smoke-test
```

The Make targets use `royd:dev`. The scripts can also be invoked directly with another image:

```sh
./runtime/scripts/smoke-test.sh example/royd:test
./runtime/scripts/multi-instance-test.sh example/royd:test
```

## Recording a reference host

A known-good result should record at least:

```text
royd commit:
Android baseline:
image architecture:
host distribution:
host kernel:
Docker version:
cgroup mode:
CPU:
RAM:
GPU device passed to container, if any:
single-instance smoke test:
two-instance smoke test:
```

Record the exact container memory limit, display profile, graphics mode, settling time, and workload alongside any memory measurement. A successful boot is not sufficient evidence for a minimum RAM claim.

## Automated reference-host report

Once `royd:dev` is available on a real host, collect the host metadata and both runtime smoke-test results in one Markdown report:

```sh
make runtime-reference-report
```

Save it directly with:

```sh
ROYD_REPORT_OUTPUT=reference-host.md make runtime-reference-report
```

The report is generated even when a smoke test fails, and the command returns non-zero when either smoke test fails. See [`reference-hosts.md`](reference-hosts.md) for the evidence contract.
