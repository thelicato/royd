# Android 15 completion checklist

This is the finite close-out checklist for Android 15. It takes precedence over treating every unchecked historical roadmap entry as a baseline requirement. Each task requires a separate atomic Conventional Commit containing its implementation or a factual record of real acceptance. Generated evidence stays outside Git. A failed or externally blocked task remains open.

## Scope and execution

The baseline is Android 15 x86_64, the standard graphical image, software rendering, the low-memory resource profile and privileged rootful Docker, with one OCI-owned IPv4 `eth0`. The OCI image must work through Docker and Compose without the optional CLI. Android-facing features stay within a comparable phone AVD; omitted optional peripherals are acceptable.

The user's instruction to perform this checklist authorises sequential progress across tasks and commits without another Continue between them. Preserve the existing Git identity, do not amend or push, and retain unrelated changes and failed evidence. Repository ZIPs and per-task delivery patches remain waived. Repository-owned AOSP patches remain valid build inputs. Required baseline builds, packaging and local import remain authorised.

Resolve the known core faults before running the complete final acceptance set. Fixes need focused contracts and relevant real-image checks; integrated implementation changes also need CI. Reuse unchanged executable/image evidence only within its recorded scope. Do not edit a running producer, rerun for quieter logs, weaken timeouts/security/packet assertions or require an unused on-demand marker. A source/image change reopens affected candidate-specific acceptance. The final clean build and final acceptance must describe the same source/image/configuration.

Tasks are outcomes, not a promise of twelve unrelated code fixes. T01 and T02 may share a cause: keep a shared implementation cohesive and give the separate causal/regression closure its own acceptance commit. Source commits may precede their required builds, followed by a factual acceptance commit. Do not invent a change or an empty commit when an existing implementation passes.

## Required tasks

| ID | Task and completion evidence | Kind | State |
| --- | --- | --- | --- |
| T00 | Record this scope, dependencies, exclusions and commit/evidence ledger. | Repository | Complete, `82ec421` |
| T01 | Establish the current blank-window/hand-off wait on the active image. Correlate app main/render threads, display-buffer consumers and frame content with adequate thread/lifecycle coverage. Fix a demonstrated defect, or establish the exact benign transition and its limits. Retain failed captures and observer overhead. Require focused regression plus current-image UI/runtime/streaming evidence before closure. | Investigation/implementation | Open |
| T02 | Establish causal closure for retained WebView/Launcher focus ANRs. Use pre-trigger evidence or a demonstrated link to an already corrected cause; a late unrelated stack or an unrelated passing run is insufficient. Preserve the formal failures, test the affected focus/lifecycle path and keep responsiveness assertions unchanged. | Investigation/implementation | Open |
| T03 | Establish the startup pre-watchdog critical path and blocked-checker interval. Distinguish role/credential/storage samples from the actual cause; preserve durability, permissions and Watchdog policy. Require targeted startup regression and full single/multi-instance qualification after any fix. | Investigation/implementation | Open |
| T04 | Build the final candidate from clean Android build outputs with pinned AOSP/owned inputs, resolved configuration and successful CI. Preserve needed old symbols/evidence before replacing outputs. Package/import, verify source/artefact/archive/image identity and freeze the exact candidate. Later build-input fixes reopen this task. | Real build/provenance | Open |
| T05 | On that candidate, pass full runtime/security/Binder isolation and ordinary Launcher, Settings/search, DocumentsUI, WebView, storage and media workflows. Verify Docker/Compose, PID1, log forwarding, health and ADB default/required-auth acceptance/rejection. Preserve absent-feature handling without adding peripherals. Record direct Docker and CLI-independent operation. | Real-image acceptance | Open |
| T06 | Pass native/WebView IPv4 DNS/HTTPS and both certificate-denial controls in both DNS modes; ordinary/control-UID denial, metered/Data Saver enforcement/restoration and link withdrawal/recovery. Keep actual network/callback/map/packet and full pre/post runtime evidence. Unchanged platform trust remains mandatory. | Real-image network acceptance | Open |
| T07 | Qualify the enabled IPv4 accounting and recorded-history paths on the candidate: ordinary UID/API progress, denied-packet boundaries, native UDP/TCP/segmentation and explicitly flushed history across container/framework restarts. Preserve exact counter/bucket identities and permission denial. Do not relabel Ethernet or claim unsupported public history APIs. | Real-image accounting acceptance | Open |
| T08 | Complete acceptance of the enabled IPv4 quota/alert backend: controlled-link repeatability, shared threshold/exact-fit/exhaustion, replacement/removal/cancellation, real callbacks and restoration; TCP/GSO/concurrent-CPU semantics and netd/framework restart ownership/reconnection. Keep exact independent packet/byte receipts and existing failure/noise gates. Fix demonstrated faults and document explicit unsupported scope; do not infer these cases from the sequential UDP witness. | Implementation/real-image policy acceptance | Open |
| T09 | Run a defined combined ordinary-app/network/restart soak and documented multi-instance/resource workload. Retain failures, full checks, memory/CPU/health observations and actual workload/configuration. Establish usable interaction and absence of unexplained unbounded resource growth; distinguish caches from leaks. Publish measurements and limits without inventing a RAM minimum or performance advantage. | Real-image endurance/resource acceptance | Open |
| T10 | Review successful final-image reference-host evidence: live kernel/Binder/cgroup/PSI/BPF capabilities, readable configuration evidence, Docker/Compose/security settings, isolation and host-control ownership. Document the known-good prerequisites and limits. An unavailable kernel configuration remains unavailable, never a fabricated minimum; obtain missing external host evidence where required. | Host acceptance | Open |
| T11 | Review the final same-candidate evidence ledger, resolve stale/failed claims, update the scoped support matrix and runtime instructions, and retain checksummed local image/archive provenance. Mark only this baseline complete, with declared limitations. No remote publication/push is authorised. | Repository/release acceptance | Open |

T01 through T03 may require several diagnostic or fix commits. Complete every task's stated acceptance before marking it done; do not count a source-only fix as rebuilt-image acceptance. T05 through T10 can run against a candidate while independent work progresses, but their final receipts must remain valid for T04's final source/image. Failures lead to diagnosis and affected requalification, not passing retries that erase earlier outcomes.

## Existing candidate evidence and ledger

The starting candidate is `sha256:3ba4f8c1f19e51701b362d112a0bfe58bc925e8e8e8ce752b944a78636653f5e`, built from `a28b296` and locally available as `royd:dev`. These receipts retain their original scope until relevant inputs change:

- Task177: full qualification/Binder companions and five-minute scrcpy pass. Blank application-area samples and 18 streaming hand-off warnings remain unresolved; decoding is not continuous visual acceptance.
- Task178, `b1ea0d1`: ordinary-UID DNS/native/WebView HTTPS and self-signed denial pass in both Docker DNS modes.
- Task179, `2a897a6`: all five generic restart/persistence phases and verified native framework power tracing pass. This does not establish network/history/quota continuity across restart.

Retained completion reports and checksum manifests are under `.work/task177*`, `.work/task178*` and `.work/task179*`. Add each new task's commit and evidence reference here when it is completed. Earlier failed evidence remains retained even when its specific cause is subsequently corrected.

T01 is active. Task181 retained three instrumented app/display captures, including a failed Settings-native capture and explicit later-thread/out-of-order/observer gaps. Task182 independently demonstrates a software Vulkan presentation-ordering defect and implements Patch0085 with source contracts and a real native probe; rebuilt-image acceptance is pending. This subtask does not close the hand-off cause or T02/T03.

## Separate follow-up work

- C01: independently qualify a pinned comparator on a disposable kernel-isolated host, reviewing host-global side effects and actual build/renderer/configuration parity.
- C02: perform at least five alternating fresh-data repetitions per image through the common measurement procedure, retaining failures and reporting ranges/unmeasured metrics. A preliminary comparison can precede broader release acceptance once its own gate passes; see [benchmarking](benchmarking.md#preliminary-android-15-comparison-gate).

Neither comparator performance nor an empty log is an Android 15 completion requirement. Other Android versions, arm64, other image/display/resource profiles, host GPU, rootless/alternative engines, minimum-capability promotion, physical printing/Bluetooth/NFC/camera/telephony and exhaustive unsupported deep links are outside this baseline. IPv6-only/multi-NIC/VPN/private-DNS and additional certificate-failure matrices remain separately declared compatibility work, without a support claim from these IPv4 tests.

## Estimates

Allow roughly 1-2 active hours for a bounded diagnostic or known fix/build/qualification cycle on the present host. This is not a total completion forecast. T01-T03 and defects found by T08 can require multiple cycles; clean builds, endurance and reference/comparator host availability add separate elapsed time. Update estimates from actual results rather than restoring the withdrawn 2-3-week forecast.
