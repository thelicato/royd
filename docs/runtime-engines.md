# Runtime engine compatibility

Reviewed against current upstream engine documentation on 20 September 2026.

royd targets OCI-compatible container execution, but engine portability and repository tooling portability are separate concerns. The Android root filesystem and its runtime contract are intended to remain engine-independent. The current repository automation is Docker-specific and must not be described as Podman-qualified or generally engine-qualified until the same evidence gates pass on those engines.

## Current status

| Interface | Repository status | Current boundary |
| --- | --- | --- |
| Docker Engine, rootful | Configured primary interface | Import, run, logs, exec, inspect, health, volumes, port publication, security evidence, and qualification tooling are implemented. Real-host Android qualification is still outstanding. |
| Docker Compose v2 | Configured primary interface | The checked-in Compose files and Make wrappers target `docker compose`. Real-host Android qualification is still outstanding. |
| Podman, rootful | Compatibility candidate | Podman exposes comparable run, capability, device, port, health-check, log, exec, volume, and inspect concepts, but royd does not yet have Podman-specific import or qualification tooling. |
| `podman compose` | Compatibility candidate | Podman's command delegates to an external Compose provider. royd has not validated its overlays against the provider combinations Podman can select. |
| Docker or Podman, rootless | Evaluated candidate | Kernel binderfs supports user-namespace mounts, but Android boot and engine-specific rootless behaviour remain unqualified. See [`rootless.md`](rootless.md). |
| Other high-level container engines | Unconfigured | No repository launcher, import path, evidence collector, or qualification gate exists for them. |
| Low-level OCI runtimes such as `runc` or `crun` | Engine implementation detail | royd does not currently expose a direct OCI bundle workflow or claim support for invoking a low-level runtime by hand. |

`configured` here means that repository-owned tooling exists. It does not mean `runtime-qualified` or `supported`; those terms retain the meanings in [`support-policy.md`](support-policy.md).

## Image import is currently engine-specific

`android/scripts/package.sh` produces a root-filesystem tar archive plus an integrity manifest. That tar file is not itself an OCI image archive. `runtime/scripts/import.sh` currently creates the runnable local image with `docker import` and injects the royd entrypoint, default display arguments, exposed ADB port, health check, OCI and royd labels, and target platform at import time.

This matters for Podman. Current Podman documentation supports importing a root-filesystem tar and applying several image configuration changes, including `CMD`, `ENTRYPOINT`, `EXPOSE`, and `LABEL`, but its documented `podman import --change` instruction set does not include `HEALTHCHECK`. Podman can execute image-defined or run-time health checks, but royd has no repository-owned Podman import path that proves equivalent image metadata today.

Do not call a manually imported Podman image contract-equivalent merely because it starts. Image identity, health behaviour, entrypoint, command, labels, exposed port, and architecture must all be verified before qualification evidence is comparable.

## Runtime flag similarities are not qualification

The rootful Docker and Podman CLIs both provide the broad mechanisms royd needs, including privileged execution, explicit capabilities, device passthrough, named volumes, published ports, health checks, logs, exec, and inspect operations. Their security and inspection models are not byte-for-byte interfaces.

Docker privileged mode grants all capabilities, broad device access, and relaxes its normal seccomp and LSM confinement. Podman privileged mode similarly disables several isolation controls, but Podman explicitly states that a container running in a user namespace cannot gain more privileges than the user that launched it. Rootless behaviour is evaluated separately in [`rootless.md`](rootless.md) because namespace-scoped privilege changes the meaning of otherwise similar runtime flags.

The experimental royd security profile is also not engine-neutral evidence. `runtime/scripts/security-evidence.sh` reads Docker-specific inspect fields such as `HostConfig.Privileged`, `HostConfig.CapAdd`, `HostConfig.CapDrop`, `HostConfig.SecurityOpt`, and `AppArmorProfile`. Podman may expose corresponding concepts through a different inspect schema or host security model. A Podman port must collect equivalent kernel-visible PID 1 evidence without pretending Docker JSON is a portable contract.

Do not qualify royd by replacing the `docker` executable with an alias or compatibility wrapper for Podman. Podman's Docker-compatible CLI is useful for interactive migration, but royd scripts depend on Docker-specific import metadata, inspect output, Compose invocation, and evidence semantics.

## Compose differences

The repository Compose files use ordinary service features such as `privileged`, `cap_drop`, `cap_add`, named volumes, explicit port publication, and an optional `/dev/dri` device overlay. Docker Compose v2 is the configured implementation.

`podman compose` is a wrapper around an external Compose provider, currently documented to select an installed provider such as `docker-compose` or `podman-compose`. Provider selection can therefore change behaviour independently of the Podman engine version. Before royd can call Podman Compose configured, validation must pin or record the provider and prove that all checked-in overlays resolve to the intended runtime configuration.

## Engine-sensitive royd behaviours

A new high-level engine must preserve these behaviours before it can be treated as configured or qualified:

1. Import or consume an image with the exact royd image identity, entrypoint, command, health check, labels, architecture, and exposed-port contract.
2. Start Android with `/init` as PID 1 after the royd entrypoint performs its bounded bootstrap.
3. Permit a private binderfs mount and independent Binder device allocation per container under the selected security mode.
4. Preserve named `/data` volume behaviour without hidden host mutation.
5. Publish ADB to loopback by default and make the effective host port discoverable to qualification tooling.
6. Preserve image health checks and expose their state to automation.
7. Capture complete container stdout and stderr so Android logcat and failed-boot diagnostics remain reviewable.
8. Provide exec and inspect facilities sufficient for runtime, graphics, security, and Binder-isolation evidence.
9. Pass `/dev/dri` explicitly for experimental host-GPU profiles without changing the software-rendering default.
10. Run the single-instance, multi-instance, Binder-isolation, security, ADB, log-forwarding, and persisted qualification gates with engine identity recorded in the evidence.

Differences discovered while proving these behaviours belong in engine-specific documentation and evidence. They must not be hidden behind generic command aliases.

## Podman qualification work still required

Podman rootful qualification does not require a new Android architecture, but it does require repository work plus a real booting image and Linux host. At minimum:

- define an image import or transfer path that preserves the complete image contract;
- make host preflight and runtime orchestration select the engine explicitly rather than by executable aliasing;
- add engine-aware log, health, port, inspect, and security evidence collection;
- define Compose provider recording if `podman compose` is included in the supported workflow;
- run the same reference-host and runtime qualification gates used for Docker and compare any Binder, LSM, seccomp, cgroup, volume, network, and device differences.

Until those steps are complete, Podman is a documented compatibility candidate, not a supported royd runtime. Rootless operation has a separate feasibility assessment in [`rootless.md`](rootless.md), but still requires real-image qualification.

## Upstream references

- [Docker running containers](https://docs.docker.com/engine/containers/run/)
- [Docker `container run`](https://docs.docker.com/reference/cli/docker/container/run/)
- [Docker Compose services](https://docs.docker.com/reference/compose-file/services/)
- [Podman `run`](https://docs.podman.io/en/latest/markdown/podman-run.1.html)
- [Podman `import`](https://docs.podman.io/en/latest/markdown/podman-import.1.html)
- [Podman `compose`](https://docs.podman.io/en/latest/markdown/podman-compose.1.html)
- [OCI Runtime Specification](https://specs.opencontainers.org/runtime-spec/)
