# Roadmap

The current priority is acceptance of the Android 15 container baseline. Detailed release gates live in the [completion checklist](android15-completion.md); validation status is distinct from implementation and support. Read [known limitations](known-limitations.md) before interpreting local results.

## Android 15 baseline

| Area | Implemented foundation | Remaining acceptance |
| --- | --- | --- |
| Product/build | Independent pinned AOSP products, owned integration/patches, resolved configuration checks, OCI packaging and image metadata. | Final clean build and exact source/archive/image provenance. |
| Container lifecycle | Init as PID1, private binderfs, delegated cgroup-v2 memory, memfd, persistent data, health and stdout/stderr logging. | Same-candidate Docker/Compose, Binder isolation, ADB modes and restart acceptance. |
| Apps and graphics | ANGLE/SwiftShader, memfd allocator/mapper, client composition, software codecs, scoped presentation/vsync/worker corrections and optional-feature Settings handling. | Final ordinary-app/search/storage/media workflows, streaming, focus/lifecycle and single/multi-instance responsiveness. |
| Networking | OCI-owned IPv4 publication, DNS/TLS, cgroup UID/metered/Data Saver policy, TCX accounting/quotas and real alert callbacks. | Final DNS modes, enforcement/restoration, segmentation, recorded history, concurrency and service recovery. |
| Resources | Low-memory/default display, optional resource/display profiles and measurement tooling. | Defined combined soak, multi-instance workload and reviewed resource growth. No RAM minimum or speed claim. |
| Host/security | Explicit host contract, scoped host-control protections, experimental exact-capability policy and reference-host bundle tooling. | Reviewed final baseline host/kernel/security evidence. Privileged Docker remains the baseline. |
| Documentation/release | Runtime/build/validation guides and explicit limitations. | Final same-candidate support review and release instructions. |

Historical ANR/watchdog causes remain partly unestablished and are accepted as documented uncertainty. This does not waive any final-candidate responsiveness or security check, change Watchdog policy or permit passing retries to erase failures.

## Compatibility evaluation

- [x] Evaluate rootless operation separately. The host feasibility probe is implemented; real Android boot, security, resource limits and engine acceptance remain unqualified. See [rootless operation](rootless.md).

## Follow-up priorities

1. Independently qualify a pinned Android-container comparator on a safe disposable host and perform repeated matched measurements. This is separate from product dependencies and wider release support.
2. Measure normal-RAM/performance resource behaviour under representative workloads; tune only demonstrated bottlenecks.
3. Qualify host-GPU backends on real DRM hardware, with separate evidence from software rendering.
4. Investigate minimum capabilities/devices/mounts with one-at-a-time removals and real workloads before promoting restricted mode.
5. Qualify arm64 and other pinned Android releases through clean build, package and runtime gates.
6. Evaluate Podman/rootless and broader network/storage compatibility as separate contracts.

A comparable phone AVD is the Android-facing feature ceiling. Optional omitted peripherals are not required merely for feature completeness. The OCI image remains the product; no roadmap item may make the CLI, a daemon or a host bootstrap service mandatory.

## Contribution and evidence rules

Keep each change cohesive, tested at the affected layer and independently revertible. Use [build validation](build-validation.md), [runtime qualification](runtime-qualification.md) and [reference-host evidence](reference-hosts.md) before changing support claims. Generated evidence stays outside Git; retain failures and exact image/configuration identities. User documentation describes current interfaces and limitations rather than a development-task log.
