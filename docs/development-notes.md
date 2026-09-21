# Development handoff notes

## Task 041 complete

Problem addressed: establish the Android 15 kernel-less product/VINTF foundation discovered by the first real AOSP build, without weakening normal VINTF validation or starting the modern graphics HAL migration.

Important evidence and changes:

- AOSP `android-15.0.0_r36` defaults `PRODUCT_OTA_ENFORCE_VINTF_KERNEL_REQUIREMENTS` to true for sufficiently new shipping API levels when the product leaves it empty. Its build rules warn when that setting is true but neither an installed kernel nor boot image exists. royd intentionally has `TARGET_NO_KERNEL := true` and no guest boot image, so the modern product family now resolves `PRODUCT_OTA_ENFORCE_VINTF_KERNEL_REQUIREMENTS := false` explicitly.
- This OTA kernel metadata setting is separate from normal framework/vendor VINTF compatibility. Task 041 does not set `PRODUCT_ENFORCE_VINTF_MANIFEST := false`, lower a framework compatibility level, patch AOSP, or invent a kernel/boot image.
- Android V uses FCM level `202404`. Android 15 now selects a committed repository-owned `device/royd/vintf/manifest-15.xml` through `DEVICE_MANIFEST_FILE`. The foundation manifest has `target-level="202404"` and deliberately contains no HAL declarations yet.
- The Android 15 manifest does not claim legacy HIDL graphics composer 2.4 compatibility. The previous real build already showed that composer contract is rejected by the Android 15 framework matrix. Modern graphics declarations must be added only with their actual implementations in later tasks.
- `android/scripts/install-royd.sh` now validates the optional version-owned manifest path and wires it into the installed version-specific board fragment. Android 14 is covered by a regression check proving it does not silently inherit the Android 15 manifest.
- `android/scripts/contract-lines.sh` and the resolved config preflight now require `PRODUCT_OTA_ENFORCE_VINTF_KERNEL_REQUIREMENTS=false` for the modern product family.
- Added `android/scripts/vintf-contract-test.sh`, `make android-vintf-contract-test`, and CI integration. The test parses the committed XML, verifies the exact Android 15 target level, checks installation/wiring, rejects a premature graphics declaration, and guards against repository-owned disabling of normal VINTF validation.
- AOSP Android 15 can emit a separate warning when `PRODUCT_ENABLE_UFFD_GC` remains `default` but no packaged kernel version is available. Task 041 does not choose a userfaultfd GC policy because royd uses the host kernel and that policy requires separate runtime/host validation.

Files/interfaces changed:

- `android/compat/modern/product.mk`
- `android/versions/15.env`
- `android/royd/device/royd/vintf/manifest-15.xml`
- `android/scripts/install-royd.sh`
- `android/scripts/contract-lines.sh`
- `android/scripts/config-check-test.sh`
- `android/scripts/aosp-shell-test.sh`
- `android/scripts/matrix-report-test.sh`
- `android/scripts/vintf-contract-test.sh`
- `Makefile`
- `scripts/ci.sh`
- `docs/development-notes.md`

Validation actually performed:

- Shell syntax checks passed for the changed shell scripts.
- `android/scripts/vintf-contract-test.sh` passed.
- `android/scripts/config-check-test.sh` passed, including a negative Android 15 case with kernel OTA VINTF enforcement resolved to true.
- `android/scripts/contract-test.sh`, `android/scripts/version-test.sh`, and `android/scripts/graphics-contract-test.sh` passed.
- Full `make ci` completed with exit code 0 on 2026-09-21 after the final task 041 repository changes.
- Repository policy scans found no em dash characters and no prohibited prior-art name references outside `docs/acknowledgements.md`.
- Roadmap remains 63 checked and 24 open. Task 041 closes no roadmap checkbox because the relevant build/VINTF items require a real resolved AOSP build or runtime evidence.

External validation still required:

- A real Android 15 config check must confirm AOSP resolves `PRODUCT_OTA_ENFORCE_VINTF_KERNEL_REQUIREMENTS=false` for both royd products.
- A real Android 15 build must confirm the repository-owned manifest is assembled into the vendor image and removes the previous missing-manifest failure without disabling normal VINTF checks.
- Normal VINTF is expected to continue failing until the Android 15 graphics family is migrated away from the currently configured HIDL composer 2.4 and gralloc0-era allocation path.

Unresolved failures or questions:

- Android 15 still configures `ANDROID_GRAPHICS_COMPOSER=2.4` and `ANDROID_GRAPHICS_ALLOCATOR=gralloc0-memfd`; those are not claimed to satisfy FCM `202404`.
- The exact Android-version boundary and AOSP contracts for the repository-owned modern allocator/mapper family still need to be pinned before implementation.
- The composer3 service design and its client-composition behaviour remain unimplemented.
- Android 10 and legacy-family kernel/VINTF behaviour has not been changed by task 041; this task deliberately targets the modern family containing the Android 15 baseline.
- Userfaultfd GC selection on a host-kernel runtime remains an explicit research/runtime-validation question rather than a build-time assumption.

Recommended next task: task 042 should pin the Android 15 allocator/mapper requirements from `android-15.0.0_r36` and implement the smallest repository-owned modern software allocator/mapper foundation. Do not add composer3 in the same task unless exact AOSP build contracts make it inseparable.

Paid external build recommendation: keep the build host off for now. The legacy Android 15 graphics mismatch is already known, so another full build after task 041 is likely to stop at normal VINTF graphics requirements rather than provide enough new evidence to justify the cost.

Exact Android 15 command when external validation becomes useful again:

```sh
cd /root/royd
./build.sh \
  --android 15 \
  --arch x86_64 \
  --profile standard \
  --hal-profile graphical \
  --graphics software \
  --sync-jobs 1 \
  --jobs "$(nproc)"
```

Expected evidence to return: `.work/logs/android15-x86_64-standard-graphical-software.log`, or the first genuine failure with approximately 100 surrounding lines. For task 041 specifically, useful evidence is `PRODUCT_OTA_ENFORCE_VINTF_KERNEL_REQUIREMENTS=false`, successful assembly of `device/royd/vintf/manifest-15.xml` into vendor VINTF metadata, absence of the old missing `vendor/manifest.xml` failure, and normal VINTF remaining enabled. A graphics compatibility failure is expected until later graphics tasks are complete and must not be bypassed.
