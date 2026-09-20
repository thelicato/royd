# Runtime security

royd currently has two runtime security modes.

## Privileged mode

`privileged` is the development baseline and remains the default until the reduced profile has passed real-host boot tests. Docker privileged mode grants all Linux capabilities, access to all host devices, and relaxes normal container security restrictions. This is useful while discovering requirements, but it is not the intended long-term configuration.

Use it directly with:

```sh
docker run --privileged ... royd:dev
```

The normal Compose configuration uses this mode unless `ROYD_SECURITY_MODE` is changed.

## Experimental restricted mode

`experimental` removes `--privileged` and currently adds only these capabilities:

```text
SYS_ADMIN
NET_ADMIN
SYS_NICE
SYS_RESOURCE
SYS_PTRACE
```

The current rationale is:

| Capability | Reason being tested |
| --- | --- |
| `SYS_ADMIN` | Mount a private binderfs instance and perform Android mount operations. |
| `NET_ADMIN` | Allow Android networking services to configure their container network state. |
| `SYS_NICE` | Allow Android scheduling and priority adjustments. |
| `SYS_RESOURCE` | Allow Android services to adjust resource limits where required. |
| `SYS_PTRACE` | Allow Android process and memory-management components that may require cross-process inspection. |

This list is an inventory candidate, not a supported minimum. Each capability must eventually be justified by a failing test before it is retained.

Run the single-instance experiment with:

```sh
make runtime-smoke-test-experimental
```

Run the multi-instance experiment with:

```sh
make runtime-multi-test-experimental
```

Or use Compose:

```sh
ROYD_SECURITY_MODE=experimental make runtime-up
```

The Compose wrapper adds `runtime/compose.experimental.yaml` automatically in that mode.

The optional CLI exposes the same experiment:

```sh
royd run --security experimental
```

## Security contract checks

The repository validates that the two modes remain distinct:

```sh
make runtime-security-contract-test
```

This is a static and command-construction test. It does not prove that Android boots under the experimental capability set.

## Comparison report

Run both modes through the same single-instance and two-instance validation with:

```sh
ROYD_SECURITY_SWEEP_OUTPUT=security-sweep.md make runtime-security-sweep
```

The report captures pass or fail status and failure diagnostics for each mode. It deliberately does not declare the experimental capability set minimal.

## Reduction process

Privilege reduction should proceed from evidence:

1. Establish a known-good privileged boot on a reference host.
2. Run the same image and workload under `experimental` mode.
3. Capture failures from `docker logs`, kernel audit output where available, and the reference-host report.
4. Add or remove one requirement at a time.
5. Repeat single-instance, multi-instance, ADB, logging, networking, and memory tests.
6. Promote a reduced profile to supported only after it passes the documented validation matrix.

Do not work around missing privileges by installing host modules, changing host security policy silently, or reintroducing a mandatory host helper.
