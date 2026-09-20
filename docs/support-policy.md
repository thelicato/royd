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
8. documented memory workload
9. documented security mode
10. reference-host compatibility record

Support claims must state the Android version, architecture, image profile, HAL profile, and security mode they cover.

## Evidence ownership

Generated build and runtime qualification reports under `.work` are local evidence and are not source-of-truth code. A release should only be promoted in repository documentation after the underlying reports have been reviewed and the relevant test environment has been documented.

Build, package, runtime, and memory evidence must refer to the exact Android image-profile policy revision. The OCI image records that policy and its SHA-256 so evidence from an older minimal package set is not silently reused after the profile changes.
