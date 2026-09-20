# Runtime security

royd currently has two runtime security modes. `privileged` is the development baseline. `experimental` exists to measure and reduce the runtime privilege surface, but it is not yet a supported minimum.

## Privileged mode

Use the baseline directly with:

```sh
docker run --privileged ... royd:dev
```

Docker privileged mode grants all Linux capabilities, broad host-device access, and relaxes the normal container security profiles. It is intentionally retained until the independent Android build and boot path is proven on reference hosts.

## Experimental exact-capability mode

The experimental profile is repository-owned and versioned. The current profile ID is:

```text
experimental-v2-exact-caps
```

The runtime first applies:

```text
--cap-drop=ALL
```

It then adds an explicit capability inventory from `runtime/security/experimental.env`. This is important because Docker normally keeps a default set of capabilities even when `--privileged` is absent. The current inventory starts with Docker's documented default kept set and then adds the five royd-specific elevated candidates that were present in the earlier experiment.

The rationale and reduction status for every capability are tracked in `runtime/security/experimental.capabilities`. The five royd-specific candidates are:

| Capability | Candidate rationale |
| --- | --- |
| `SYS_ADMIN` | Mount the private binderfs instance and perform Android mount operations. |
| `NET_ADMIN` | Allow Android networking services to configure container network state. |
| `SYS_NICE` | Allow Android scheduling and priority adjustments. |
| `SYS_RESOURCE` | Allow privileged resource-limit changes where Android requires them. |
| `SYS_PTRACE` | Preserve userdebug cross-process diagnostics while testing whether they can be removed. |

The complete list is deliberately larger than the long-term target. Making it explicit and deterministic is the prerequisite for proving which entries can be removed.

Run it with:

```sh
make runtime-smoke-test-experimental
make runtime-multi-test-experimental
```

Or use Compose:

```sh
ROYD_SECURITY_MODE=experimental make runtime-up
```

The optional CLI uses the same exact list:

```sh
royd run --security experimental
```

## Profile identity

Every security profile has a stable ID and a SHA-256 derived from its repository policy files:

```sh
runtime/scripts/security-profile.sh experimental id
runtime/scripts/security-profile.sh experimental digest
```

Runtime qualification records both values. A profile-policy change invalidates a previously passing resumable qualification result, so old security evidence cannot silently survive a capability change.

## Runtime evidence

`runtime/scripts/security-evidence.sh` records both the configured OCI security state and the kernel-visible state of Android PID 1. Evidence includes:

- Docker privileged mode
- configured capability additions and drops
- Docker security options
- active AppArmor profile when reported by Docker
- PID 1 inheritable, permitted, effective, bounding, and ambient capability masks
- PID 1 `NoNewPrivs`
- PID 1 seccomp mode and filter count

Linux exposes the capability, no-new-privileges, and seccomp values through `/proc/<pid>/status`. Runtime qualification treats successful evidence capture as a separate required stage.

## Capability reduction sweep

Once an image boots under the exact experimental baseline, run:

```sh
ROYD_SECURITY_CAPABILITY_SWEEP_OUTPUT=security-capabilities.md \
make runtime-security-capability-sweep
```

The sweep removes one capability at a time and reruns the same single-instance and two-instance validation. A passing removal is reported only as a candidate for further qualification. It is not proof that the capability is unnecessary across Android versions, architectures, graphics backends, workloads, or hosts.

The broader privileged-versus-experimental comparison remains available with:

```sh
ROYD_SECURITY_SWEEP_OUTPUT=security-sweep.md make runtime-security-sweep
```

## Seccomp and LSM policy

The experimental profile does not currently force seccomp unconfined, AppArmor unconfined, SELinux label changes, or `no-new-privileges`. Those controls are intentionally measured rather than changed speculatively.

Docker's default seccomp profile adjusts some syscall permissions according to the selected capabilities. AppArmor is separate: on AppArmor-enabled Docker hosts, the default `docker-default` profile can deny mount operations even when `SYS_ADMIN` is present. Because royd mounts binderfs inside the container, qualification must record the actual LSM and seccomp state and any required exception before the reduced mode can become a supported default.

## Reduction process

Privilege reduction should proceed from evidence:

1. Establish a known-good privileged boot on a reference host.
2. Boot the same image under the exact experimental profile.
3. Capture runtime qualification and security evidence.
4. Run the one-capability-at-a-time sweep.
5. Remove only candidates that pass the relevant Android versions, architectures, profiles, and workloads.
6. Record any seccomp, LSM, device, cgroup, or system-path exception that remains necessary.
7. Promote a reduced profile only after the documented qualification matrix passes.

Do not work around missing privileges by installing host modules, changing host security policy silently, or introducing a mandatory host helper.
