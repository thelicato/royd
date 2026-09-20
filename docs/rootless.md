# Rootless operation

Reviewed against current Linux kernel, Docker, and Podman documentation on 20 September 2026.

Rootless execution is a separate compatibility dimension from the rootful Docker and Podman work described in [`runtime-engines.md`](runtime-engines.md). This investigation finds no kernel-level Binder reason to reject rootless royd outright, but it also does not establish that Android boots correctly under a rootless engine.

## Research conclusion

Rootless royd is an **unqualified compatibility candidate**, with software rendering as the first path worth validating. It is not configured, runtime-qualified, or supported.

The key enabling fact is binderfs. Current Linux kernel documentation states that binderfs can be mounted in user namespaces, and a fresh mount exposes `binder-control` for allocating private Binder devices. The upstream binderfs implementation registers the filesystem with `FS_USERNS_MOUNT`. This matches royd's existing private-binderfs architecture rather than requiring host-created `/dev/binder*` devices.

Rootless engines still place the container inside a user namespace. Capabilities such as `SYS_ADMIN` are therefore scoped to resources governed by that namespace and do not become host-root privileges. Docker documents the same limitation for rootless capability additions, while Podman states that a rootless container cannot gain more privilege than the account that launched it. This is compatible with binderfs in principle because binderfs deliberately supports user-namespace mounts, but it means every other Android operation that expects initial-user-namespace privilege must be discovered by real boot evidence.

## Host-side feasibility probe

Run the repository probe as the same unprivileged account that would own the rootless container engine:

```sh
make runtime-rootless-probe
```

The probe does not start Android and does not require a royd image. It checks:

- Linux and binderfs availability;
- `newuidmap`, `newgidmap`, and subordinate UID/GID ranges expected by rootless engines;
- cgroup v2 availability for resource-control work;
- creation of an unprivileged user namespace;
- a real private binderfs mount from that namespace;
- presence of `binder-control` in the user-namespace binderfs instance;
- direct access to a DRM render node when one exists.

A passing probe means only that the host is a reasonable candidate for rootless Android qualification. It is intentionally weaker than `make runtime-qualification`.

A failed direct `unshare` check is also not proof that a configured rootless engine must fail. Host LSM policy can grant user-namespace creation to specific launchers while denying a generic `unshare` process. Treat that result as unverified feasibility and investigate the intended engine policy before drawing an engine-level conclusion.

The probe should normally be run as a non-root user. Running it as UID 0 is useful only for debugging and produces a warning because it does not model a normal rootless account.

## Docker rootless boundary

Docker rootless mode runs both the daemon and containers inside a user namespace. Its current documented prerequisites include `newuidmap`, `newgidmap`, and at least 65,536 subordinate UIDs and GIDs for the account.

royd's published ADB port is 5555, so it does not need the special handling Docker documents for rootless publication of ports below 1024. Normal `-p` publication remains the interface to validate.

Resource limits need more care. Docker documents rootless cgroup resource controls as supported only with cgroup v2 and systemd, and notes that controller delegation can still be narrower than the full host controller set. This matters directly to royd memory benchmarking and `lmkd` work. A rootless boot without enforceable memory limits must not be used as evidence for memory-limit claims.

Docker also documents that capabilities added in rootless mode remain limited by the container's user namespace. The current royd privileged and experimental security modes therefore cannot be assumed equivalent to their rootful forms simply because the CLI accepts the same flags.

## Podman rootless boundary

Podman also creates a user namespace for rootless execution and requires subordinate UID/GID configuration for the normal multi-ID model. Its documentation states that rootless privileged containers cannot gain more privileges than the launching user.

For host devices, Podman documents rootless access as a bind of a device the launching user can already access. On SELinux systems this can additionally require host policy allowing container device use, and supplementary-group-only access needs explicit handling. For royd this makes software rendering the clean first qualification target. Experimental `/dev/dri` use should be evaluated only after software rootless boot succeeds, and only with the render node already accessible to the launching account.

Podman rootless does not remove the separate engine-portability work described in [`runtime-engines.md`](runtime-engines.md). The image-import and evidence-tooling differences still have to be solved before Podman, rootful or rootless, can produce comparable royd qualification evidence.

## Android validation still required

The host probe cannot determine whether Android `/init` and all required services behave correctly with user-namespace-scoped privilege. Rootless qualification therefore requires a real built image and a documented host.

The first rootless qualification attempt should use:

1. software graphics, with no `/dev/dri` passthrough;
2. the normal loopback ADB publication;
3. a private binderfs instance created inside the container;
4. cgroup v2 with usable memory and PID delegation when resource limits are part of the test;
5. complete container logs and failed-boot diagnostics;
6. explicit recording of engine name, engine version, rootless status, UID/GID mapping, cgroup mode, LSM, seccomp state, and effective PID 1 capabilities.

A successful boot is still insufficient for promotion. The same health, logging, ADB, Binder isolation, multi-instance, security, and runtime evidence gates used by rootful qualification must pass, with rootless engine state recorded as part of the evidence.

## Current decision

Rootless operation remains off by default and must not replace the rootful Docker development baseline yet. No mandatory privileged host helper should be introduced merely to make rootless appear to work. If a rootless engine cannot provide the required user-namespace binderfs and Android runtime semantics directly, that engine and host combination should remain unsupported.

The next rootless step is external validation with a real royd image. No additional rootless runtime implementation is justified before that result identifies an actual repository-side incompatibility.

## Upstream references

- [Linux binderfs documentation](https://docs.kernel.org/admin-guide/binderfs.html)
- [Linux binderfs implementation](https://github.com/torvalds/linux/blob/master/drivers/android/binderfs.c)
- [Docker rootless mode](https://docs.docker.com/engine/security/rootless/)
- [Docker rootless tips](https://docs.docker.com/engine/security/rootless/tips/)
- [Docker rootless troubleshooting](https://docs.docker.com/engine/security/rootless/troubleshoot/)
- [Podman rootless mode](https://docs.podman.io/en/stable/markdown/podman.1.html)
- [Podman container creation and privilege semantics](https://docs.podman.io/en/latest/markdown/podman-create.1.html)
