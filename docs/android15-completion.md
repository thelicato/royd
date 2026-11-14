# Android 15 completion checklist

This checklist defines acceptance of the first Android 15 baseline. It is a maintainer checklist, not a statement that every configured profile or Android release is supported. See [support policy](support-policy.md) and [known limitations](known-limitations.md).

## Baseline

The candidate is Android 15 x86_64, standard graphical, software rendering, low-memory resource profile and privileged rootful Docker, with one OCI-owned IPv4 `eth0`. Docker and Compose must work without the optional CLI. A comparable phone AVD is the feature ceiling; omitted optional peripherals do not by themselves block completion.

Exact causal attribution of earlier WebView/Launcher focus ANRs and startup pre-watchdogs is accepted as a historical uncertainty. Those failures remain recorded and are not described as fixed. This acceptance does not waive any final-candidate runtime, ANR, input-timeout, pre-watchdog, security, packet/noise or restoration check. A failure on the candidate requires diagnosis and affected requalification.

## Execution

Complete each outcome with an atomic Conventional Commit. Preserve failed evidence and unrelated state. Use the existing Git identity; do not amend, push or publish. Repository ZIPs and task delivery patches are waived. Required local baseline builds, packaging and import are authorised. Continue independent work until acceptance is complete or an external prerequisite is missing.

The final clean build and acceptance must refer to the same source, image and configuration. Preserve needed old symbols before replacing outputs. A later build-input fix reopens affected candidate-specific checks. Reuse unchanged evidence only within its original scope. Do not invent a source change for a passing gate, rerun for quieter logs or overwrite failed results.

## Acceptance requirements

The IDs are stable checklist references. A documented limitation is distinct from a proven fix or a passed final-candidate gate.

| ID | Requirement | Evidence/state |
| --- | --- | --- |
| T00 | Define baseline, exclusions, dependencies and acceptance policy. | Defined here. |
| T01 | Attribute sampled blank transitions and hand-off waits using app/render/consumer/layer evidence; retain coverage limits. | Scoped local attribution complete: an opaque Settings splash covers advancing app buffers; captured waits have BufferQueue backpressure/release progress. General visual quality remains unqualified. |
| T02 | Assess earlier WebView/Launcher focus ANRs without inventing a common cause. | Historical cause unestablished and accepted as a documented limitation. Final candidate must pass unchanged focus/lifecycle and full responsiveness checks. |
| T03 | Assess earlier startup pre-watchdogs without attributing a whole interval to a late stack sample. | Historical cause unestablished and accepted as a documented limitation. Checker timing diagnostics exist. Final single/multi-instance startup must pass; Watchdog policy and credential durability remain unchanged. |
| T04 | Clean Android outputs, pinned AOSP/owned inputs, resolved configuration, successful CI, package/import and verified source/artefact/archive/image provenance. Freeze the candidate. | Pending final clean build. |
| T05 | Full runtime/security/Binder isolation; ordinary Launcher, Settings/search, DocumentsUI, WebView, storage and media; Docker/Compose, PID1/logs/health and default/required-auth ADB acceptance/rejection. | Pending same-candidate acceptance. |
| T06 | Native/WebView IPv4 DNS/HTTPS and both certificate-denial controls in both DNS modes; ordinary/control-UID denial, metered/Data Saver and link withdrawal/recovery, with restoration. | Pending same-candidate acceptance. |
| T07 | Ordinary-UID/API accounting, denied-packet boundaries, native UDP/TCP/segmentation and explicitly flushed recorded history across Docker/framework restarts. Exact identities/buckets and permission denial. | Pending same-candidate acceptance. |
| T08 | Quota/alert thresholds, exact fit/exhaustion, replacement/removal/cancellation, callbacks, restoration, TCP/GSO/CPU sharing, concurrent alerts and netd/framework ownership/reconnection. | Implemented with scoped local witnesses; pending final-candidate review and affected gates. Continuous restart-window enforcement and unflushed durability are not qualified. |
| T09 | Defined combined app/network/restart soak and multi-instance/resource workload. Stable usable interaction and no unexplained unbounded growth; distinguish caches from leaks. | Pending final workload and measurements. No supported RAM minimum or speed advantage is claimed. |
| T10 | Reviewed final-image reference-host bundle: kernel/Binder/BPF/cgroup/PSI, readable configuration, Docker/Compose/security, isolation and host ownership. | Pending final host review; missing configuration stays unavailable. |
| T11 | Review same-candidate evidence, reconcile stale claims, publish scoped support status/runtime instructions and retain checksummed local image/archive provenance. | Pending final acceptance. No remote publication is authorised. |

## Existing implementation

The repository implements scoped corrections for software presentation ordering, synthetic vsync, low-RAM software worker budgets, optional Settings capabilities, host-control ownership and IPv4 policy/accounting. Local build/runtime/Binder/streaming and network fixtures have exercised these components. Their existence does not establish final clean-build acceptance or broader host support.

Use the reproducible contracts in [validation](validation.md), [graphics](graphics.md), [network quotas](network-quotas.md) and [runtime qualification](runtime-qualification.md). Record exact image/source/configuration and checksums in generated evidence, with full failed outcomes retained. Do not duplicate private trial histories in user documentation.

## Separate compatibility and comparison work

- Independently qualify a pinned comparator on a disposable kernel-isolated host, or under a separately reviewed common containment policy. Review actual build/renderer/configuration parity and host-global side effects before execution.
- Run at least five alternating fresh-data repetitions per image using [common measurements](benchmarking.md#preliminary-android-15-comparison-gate). Retain failures, report ranges and mark unmeasured metrics explicitly. A preliminary comparison need not wait for other Android versions or unrelated peripheral work.
- Other Android versions, arm64, alternative profiles, host GPU, rootless/alternative engines, minimum-capability promotion and physical peripherals are outside this baseline. IPv6-only, multi-NIC, VPN/private-DNS and additional certificate-failure cases require separate qualification.
