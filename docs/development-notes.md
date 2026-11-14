# Development guide

royd owns its AOSP integration and OCI image. Start with [architecture](architecture.md), [building](building.md) and [AGENTS.md](../AGENTS.md) for project rules. The [Android 15 completion checklist](android15-completion.md) defines the active baseline and release requirements.

## Source layout

| Path | Purpose |
| --- | --- |
| `android/royd/device/royd` | Owned products, board configuration, image/HAL profiles, properties and init integration. |
| `android/royd/vendor/royd` | Owned runtime helpers, allocation/composition and Android modules. |
| `android/patches` | Versioned AOSP changes applied by the normal build. |
| `android/scripts` and `android/tests` | Source/configuration/build contracts and focused regressions. |
| `runtime` | OCI packaging/import, Docker/Compose, host checks and real-image validation. |
| `cli` | Optional Go convenience CLI; no core runtime dependency. |
| `.work` | Generated source trees, outputs and local evidence. Never commit these. |

## Making a change

1. Inspect the relevant source, tests and current configuration. Keep stock Android behaviour outside any explicit container gate and preserve permissions and errors.
2. Add a focused regression for a demonstrated defect or a reproducible validation step. Run affected contracts; run `make ci` for integrated implementation changes.
3. Commit the cohesive change with a Conventional Commit and the configured Git identity. Do not amend or push without the appropriate instruction.
4. Rebuild/package/import after any AOSP, device, product or other image-input change. Repository-only tests do not validate a rebuilt image. See [build validation](build-validation.md).
5. Use fresh disposable resources/evidence for affected real-image checks. Preserve failed outcomes, complete logs/inspect and available dumps before ownership-checked cleanup. See [validation](validation.md).

The build reapplies/checks repository patches before compilation, including incremental builds. Do not edit installed AOSP files by hand or change already-applied patch content without controlled reverse/reapplication. Preserve old symbols and image/archive identities needed by retained diagnostics before a clean build replaces outputs.

## Documentation and claims

Write guides around current behaviour, commands, requirements and known limitations. Keep detailed trial history in Git and retained evidence; do not append numbered task reports, machine-local paths or conversational hand-offs to user documentation. Link source and reproducible checks where implementation details matter.

A passing test, local boot or streaming recording establishes only its stated scope. Use the exact image/profile/policy identity for claims. Historical causes that remain unestablished are listed in [known limitations](known-limitations.md), while every final-candidate failure gate remains mandatory. A fixed bug must not be presented as a universal responsiveness, isolation or performance guarantee.
