# Architecture

## Product boundary

The OCI image is the primary royd product. It must remain runnable with a standard OCI runtime without requiring a royd daemon, launcher, or host bootstrap binary.

The optional Go CLI is a client-side convenience layer. It may inspect host capabilities, generate container commands, manage instances, open ADB shells, and follow logs, but it must not become a runtime dependency.


## Source ownership

The Android source boundary is deliberately narrow: royd synchronises a pinned AOSP tree and overlays only code committed to this repository. Product definitions, vendor modules, Binder setup, init integration, image profiles, and any required AOSP patches are repository-owned. No other Android container project is part of the build graph.

See [`dependency-policy.md`](dependency-policy.md) for the enforceable dependency rules.

## Host and container responsibilities

The host provides the Linux kernel, a high-level container engine, and its low-level OCI runtime. The container provides Android userspace and should perform Android-specific setup inside its own namespaces wherever the kernel permits it. Docker Engine is the configured primary interface today; other engines require separate qualification. See [`runtime-engines.md`](runtime-engines.md).

The intended ownership split is:

| Concern | Host | Container |
| --- | --- | --- |
| Linux kernel | Yes | Shared |
| Container engine and OCI runtime | Yes | No |
| Binder IPC implementation | Kernel | Uses it |
| binderfs instance | Kernel facility | Mounts and manages its instance |
| Binder device allocation | Kernel facility | Requests and exposes devices |
| Android init and framework | No | Yes |
| Android data partition | Storage backing | Initialises and uses it |
| Android logs | Carries stdout/stderr | Emits `logcat` and diagnostics |
| QEMU or guest kernel | No | No |

## Binder model

royd should prefer a private binderfs instance for each Android container. The container should allocate the Binder devices it needs and expose them at the conventional paths expected by Android:

```text
/dev/binder
/dev/hwbinder
/dev/vndbinder
```

This avoids a host configuration that pre-allocates a fixed number of numbered Binder devices for future containers. The implementation must verify what privileges and mount propagation rules are required by common OCI runtimes before this is considered stable.

If binderfs cannot be mounted because the host kernel lacks the required support, startup should terminate with a concise compatibility error.

## Android process model

Android `/init` should remain PID 1. Container-specific initialisation should integrate with Android init where practical instead of introducing a general-purpose supervisor in front of Android.

A royd boot is expected to follow this sequence:

```text
container start
  -> royd entrypoint validates runtime arguments
  -> exec /init, preserving PID 1
  -> Android early-init
  -> binderfs setup and Binder device allocation
  -> early display and hardware configuration
  -> logcat forwarding to container stdout/stderr
  -> Android boot completion
```

The exact ordering may change as implementation work establishes Android init constraints.

## Memory direction

royd should reduce memory usage at build time rather than relying primarily on post-boot package disabling. Candidate work includes low-RAM framework configuration, PSI-aware `lmkd`, restrained background process behaviour, smaller display profiles, and image variants that omit hardware or framework features not required by their workload.

Memory measurements must distinguish Android process memory from host page cache and container accounting. Targets should be tied to a defined Android version, image profile, display configuration, and workload.

## Graphics direction

The runtime should eventually support at least two graphics paths:

- Host GPU acceleration where a compatible render device is explicitly passed to the container.
- Software rendering for hosts without usable GPU access.

Low-resolution and low-refresh-rate display profiles should be available for workloads that do not need a large interactive display. The `headless` HAL profile is server-oriented but still retains the minimum graphics stack Android expects for normal framework boot.

## Security direction

Privileged mode remains the development baseline while the architecture is being proven. royd also carries an experimental reduced profile with an explicit capability inventory so the same smoke and benchmark workflows can gather evidence without granting every capability and device.

Security work should focus on explicit devices, capabilities, mounts, namespace behaviour, and seccomp policy. The reduced profile must stay experimental until it passes the reference-host validation matrix. It must not introduce hidden host mutation as a substitute for understanding those requirements.
