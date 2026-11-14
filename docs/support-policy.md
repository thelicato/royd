# Support policy

royd uses explicit validation stages so that a configured Android release is not confused with a supported one.

## Status meanings

`legacy-configured` and `configured` mean the repository contains metadata and integration intended for that Android release, but clean build and runtime validation remain incomplete.

`baseline` identifies Android 15 as the current development reference. It does not imply broader runtime support than another release.

Build reports may describe an architecture tuple as `build-validated` or `package-validated`. Runtime qualification may describe it as `runtime-qualified`. These are evidence states generated from local validation records, not values written into the pinned version metadata.

A release may be described as supported only after the relevant architecture and published profiles have passed all required gates:

1. resolved AOSP product configuration
2. clean compilation
3. OCI packaging and image-contract inspection
4. Android container boot and health check
5. Binder setup and multi-instance isolation
6. software graphics, and GPU mode where published
7. ADB and container log behaviour
8. scrcpy streaming stability for published graphical profiles
9. documented memory workload
10. documented security mode
11. reference-host compatibility record

Support claims must state the Android version, architecture, image profile, HAL profile, security mode, and security-profile policy identity they cover. A security-profile digest change invalidates older runtime qualification for support purposes.

## Known limitations and historical failures

Support is scoped to reviewed candidate evidence, with limitations stated explicitly. Earlier Android 15 ANRs and startup watchdogs have incomplete causal evidence and remain unestablished; exact historical attribution is accepted as a documented limitation. This does not establish that they are fixed or permit a candidate failure to pass. Every final-candidate responsiveness/security assertion remains mandatory, and failed results remain retained. See [known limitations](known-limitations.md) and [the completion checklist](android15-completion.md).

## Evidence ownership

Generated build and runtime qualification reports under `.work` are local evidence and are not source-of-truth code. For reference-host review, `make runtime-reference-qualify` collects host, image, runtime, memory, and optional capability-reduction evidence into a checksummed bundle. `make runtime-reference-bundle-verify BUNDLE=...` must pass before that bundle is cited for a support decision. A release should only be promoted in repository documentation after the underlying build evidence and verified reference-host bundle have been reviewed and the relevant test environment has been documented.

Build, package, runtime, and memory evidence must refer to the exact Android image-profile policy revision. The OCI image records that policy and its SHA-256 so evidence from an older minimal package set is not silently reused after the profile changes.
