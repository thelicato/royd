# Development handoff notes

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
