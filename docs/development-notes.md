# Development handoff notes

## Task 046 complete

Problem addressed: the real Android 15 x86_64 software build completed successfully, then the OCI packaging stage exited before writing its manifest and the EXIT cleanup reported permission errors removing extracted `root/dev/console`, `root/dev/null`, and `root/dev/urandom`. The packaging path had two related shell defects: an absent optional partition could terminate `append_image` under `set -e`, and cleanup treated deletion of the privileged ramdisk extraction as mandatory even though that tree can contain root-owned device nodes.

Important evidence discovered:

- The returned external log reports `build completed successfully` for the Android 15 x86_64 standard, graphical, software tuple before packaging starts. This is real evidence that task 045's duplicate allocator init install rule no longer blocks this incremental build. It is not clean-build or runtime evidence.
- `package.sh` extracts the ramdisk with `sudo cpio` so Android ownership, modes, and device nodes are preserved. Its cleanup previously used unprivileged `rm -rf`, which can fail on the resulting root-owned `/dev` content. The supported builder itself is disposable because `builder.sh` launches Docker with `--rm`.
- `ANDROID_OPTIONAL_PARTITIONS` contains `odm` for Android 15. The former missing-image branch used `[ "$required" = yes ] && fail ...` followed by `return` under `set -e`. In the focused regression, an absent optional `odm.img` caused that branch to terminate packaging before the manifest. This is repository evidence of a defect, but the returned external log does not prove that `odm.img` was absent on the build host.
- The corrected branch uses an explicit `if` for required partitions and returns success for an absent optional partition. Cleanup now treats deletion of the builder-local temporary tree as best effort while still attempting normal unprivileged cleanup. No extra sudo permission was added.

Files/interfaces changed:

- `android/scripts/package.sh`
- `android/scripts/package-contract-test.sh`
- `scripts/ci.sh`
- `Makefile`
- `docs/development-notes.md`

Validation actually performed:

- The focused package contract test passed. It packages successfully with no `odm.img`, simulates a permission denial deleting the temporary ramdisk extraction, verifies that the denial is non-fatal and silent, verifies that no absent `odm` tree is added, and verifies that a missing required `vendor.img` still fails explicitly.
- `build-matrix-test.sh`, `build-helper-test.sh`, `check-runtime.sh`, `check-repo.sh`, shell syntax checks, and `git diff --check` passed.
- Literal `make ci` was attempted. No assertion failed before this execution environment terminated the combined run while entering `config-check-test.sh`. `config-check-test.sh` passed separately in 23.54 seconds. Every remaining command in `scripts/ci.sh` was then observed passing in direct runs, including the new package contract test, runtime qualification and reference-host tests, and `go test ./...`. This is not recorded as a successful literal `make ci` run.
- Roadmap remains 63 checked and 24 open. Task 046 closes no roadmap checkbox because the returned Android build was incremental, packaging still needs external confirmation, and no image has been imported or booted.

External validation still required:

- Rerun only the Android 15 x86_64 packaging stage against the existing successful build output. Confirm an absent optional partition, if any, is skipped without aborting and that cleanup no longer reports permission errors.
- Confirm the package writes both the root filesystem archive and sidecar manifest. Image import and runtime boot remain later gates.

Unresolved failures or questions:

- The returned external excerpt does not identify whether `odm.img` existed, so the optional-partition defect must not be recorded as the proven external trigger. The rerun will distinguish successful packaging from any separate underlying packaging failure that the old cleanup noise may have obscured.
- The successful Android build was incremental. A clean Android 15 build for both royd products remains required by the roadmap.
- The produced archive has not yet been imported into Docker or exercised by runtime qualification.

Recommended next task: rerun the package stage on the existing build host. Task 047 should use that result as evidence. If packaging succeeds, keep task 047 bounded to the next image-import or runtime-readiness failure rather than starting unrelated architecture work.

Exact external command on the existing build host:

```sh
cd /root/royd
env \
  ROYD_ANDROID_VERSION=15 \
  ROYD_ANDROID_PROFILE=standard \
  ROYD_HAL_PROFILE=graphical \
  ROYD_GRAPHICS_BACKEND=software \
  ROYD_BUILDER_TTY=never \
  ./android/scripts/builder.sh android/scripts/package.sh x86_64 standard
```

Expected evidence to return: the complete command output. Success must include both `Runtime manifest is ready:` and `Runtime root filesystem is ready:` and must not contain the previous `rm: cannot remove ... root/dev/...: Permission denied` lines. If it still fails, return the first genuine failure plus approximately 100 surrounding lines. Do not delete or regenerate the existing AOSP build output before this packaging-only check.

## Task 045 complete

Problem addressed: the real Android 15 x86_64 software build failed during Kati rule generation because `vendor/etc/init/allocator.rc` had two install commands. The repository-owned Android 15 allocator used the generic `allocator.rc` basename for its Soong `init_rc` file.

Important evidence discovered:

- The returned real-build log reached completion of legacy Make parsing, then `ckati` rejected duplicate commands for `out/target/product/royd_x86_64/vendor/etc/init/allocator.rc`. This is external build evidence, not a static prediction.
- royd's allocator Soong module installed `allocator/allocator.rc`, which maps its basename into the vendor init directory.
- Upstream AOSP minigbm also has an AIDL allocator init file named `allocator.rc`. This makes the generic basename unsafe in the Android build graph, although the returned log excerpt does not identify the second rule's owning module.
- The allocator init file is now named `android.hardware.graphics.allocator-service.royd.rc`. The allocator binary stem, Binder service instance, VINTF contract, mapper, composer, and product selection are unchanged.

Files/interfaces changed:

- `android/graphics/allocator-aidl2/Android.bp`
- `android/graphics/allocator-aidl2/allocator/android.hardware.graphics.allocator-service.royd.rc` renamed from `allocator.rc`
- `android/scripts/android15-build-readiness-test.sh`
- `android/scripts/graphics-contract-test.sh`
- `docs/development-notes.md`

Validation actually performed:

- `android15-build-readiness-test.sh`, `graphics-contract-test.sh`, `vintf-contract-test.sh`, `hal-contract-test.sh`, and `hal-profile-test.sh` passed.
- `config-check-test.sh` and `aosp-shell-test.sh` passed when rerun separately after the first combined command exceeded the local execution timeout.
- Full `make ci` was attempted repeatedly. In this execution sandbox the combined foreground run was externally terminated during `config-check-test.sh`; the same test passed standalone in 21.64 seconds. Every command in `scripts/ci.sh` was observed passing either before that combined-run termination or in a separate direct run, including `qualification-matrix-test.sh`, `reference-host-qualify-test.sh`, and `go test ./...`. This is not recorded as a successful literal `make ci` run.
- Repository policy scans passed: no em dashes were found, and no prohibited prior-art name references were found outside `docs/acknowledgements.md`. The generated patch passed `git apply --check`, applied cleanly to a fresh copy of the task-044 tree, and the patched tree matched the finished tree byte-for-byte and file-mode-for-file-mode. The finished ZIP round-trip matched the finished tree by the same comparison.
- Roadmap remains 63 checked and 24 open. Task 045 closes no roadmap checkbox because the Android 15 clean-build item still requires the external build to proceed beyond this failure.

External validation still required:

- Rerun the existing `android-15.0.0_r36` x86_64 software build and confirm Kati no longer reports an override for `vendor/etc/init/allocator.rc`.
- Continue through compilation, linking, installation, packaging, and normal VINTF validation. Allocator, mapper, composer VTS and real container boot remain later external gates.

Unresolved failures or questions:

- The supplied log excerpt proves a duplicate install target but does not expose the second install rule, so its owning AOSP module is not recorded as fact.
- No real build has yet compiled the repository-owned Android 15 allocator/mapper/composer family beyond Make graph generation.
- Any next generated-header, compile, link, SELinux, VINTF, packaging, or runtime failure must be treated as new evidence rather than bypassed.

Recommended next task: rerun the same Android 15 build from the patched repository. Task 046 should address only the first new genuine failure, if one appears. If the build completes, task 046 should record and inspect the resulting build/VINTF evidence before starting unrelated architecture work.

Exact external build command on the existing synced build host:

```sh
cd /root/royd
./build.sh \
  --android 15 \
  --arch x86_64 \
  --profile standard \
  --hal-profile graphical \
  --graphics software \
  --sync-jobs 1 \
  --jobs "$(nproc)" \
  --skip-sync \
  --incremental
```

Expected evidence to return: `.work/logs/android15-x86_64-standard-graphical-software.log` plus the first genuine failure with approximately 100 surrounding lines. The immediate success criterion is that Kati passes the prior duplicate `vendor/etc/init/allocator.rc` point and the build proceeds into later Ninja work. If it succeeds further, return lines showing compilation/linking and vendor installation of `android.hardware.graphics.allocator-service.royd`, `mapper.royd`, and `android.hardware.graphics.composer3-service.royd`, plus normal `check_vintf` output. Do not bypass VINTF, SELinux, or build failures.
