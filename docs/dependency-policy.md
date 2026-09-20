# Dependency policy

royd is built from a pinned AOSP source baseline plus code stored in this repository.

## Allowed Android source dependency

The normal Android source synchronisation path may fetch:

- the AOSP manifest configured in `android/baseline.env`
- the AOSP projects referenced by that manifest
- Git LFS objects required by those AOSP projects

The resolved AOSP manifest is recorded in `.work/android-manifest.lock.xml`.

## Repository-owned integration

The following must be committed to royd rather than fetched from another Android container project:

- product and device definitions
- vendor integration
- Binder allocation helpers
- init rules and boot helpers
- runtime parameter handling
- Android image profiles
- AOSP source patches
- OCI packaging and import logic
- host diagnostics and validation scripts

Repository-owned AOSP patches belong under `android/patches/<AOSP tag>` and are applied in lexical order.

## Prior art

Other Android container projects may be studied as prior art, but they must not become hidden build or runtime dependencies. When a design is materially influenced by another project, credit it in [`acknowledgements.md`](acknowledgements.md) and prefer an independent implementation based on upstream Linux and AOSP interfaces.
