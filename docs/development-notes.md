# Development handoff notes

## Task 043 complete

Problem addressed: replace Android 15's legacy HIDL composer selection with the smallest repository-owned composer3 V3 service required by the pinned `android-15.0.0_r36` graphics contract, while keeping software composition in SurfaceFlinger/RenderEngine.

Important evidence and changes:

- The frozen composer3 V3 `IComposerClient` contract in AOSP exposes the methods implemented by the new service, and Android 15's composer VTS accepts explicit `EX_UNSUPPORTED` responses for unadvertised overlay, brightness, doze/suspend, readback, boot-display, ALLM, sampling, and related optional capabilities.
- Android 15 now selects `ANDROID_GRAPHICS_COMPOSER=aidl3-client`; Android 14 and the other pinned versions retain their previous HIDL composer selection until researched separately.
- Added `android.hardware.graphics.composer3-service.royd`, a repository-owned AIDL composer3 V3 service with one fixed internal display, configurable width/height/dpi/fps, callback hotplug/vsync, no virtual displays, and client-composition-only layer validation.
- The composer advertises no optional capabilities it does not implement. It explicitly rejects unsupported display brightness and power modes, and accepts only the VTS-defined `SRGB_LINEAR` saturation-matrix query.
- Android 15 product fragments package composer3 instead of `hwcomposer.default`, the device manifest declares composer3 V3, and vendor SELinux labels the service executable with the standard graphics-composer executable domain.
- Android 15's software graphics family is now allocator AIDL V2 + stable-C mapper V5 + composer3 V3. No emulator, goldfish, ranchu, Cuttlefish runtime, QEMU, AOSP patch, VINTF bypass, generated emergency manifest, or command spoofing was introduced.
- Experimental host-GPU product fragments select composer3 on Android 15, but the Android 15 host-GPU allocator path is still not qualified against the modern allocator/mapper contract. Software remains the build-validation target.

Files/interfaces changed:

- `AGENTS.md`
- `android/graphics/composer-aidl3/Android.bp`
- `android/graphics/composer-aidl3/composer/Composer.cpp`
- `android/graphics/composer-aidl3/composer/Composer.h`
- `android/graphics/composer-aidl3/composer/composer.rc`
- `android/graphics/composer-aidl3/composer/main.cpp`
- `android/graphics/software.mk`
- `android/graphics/host-gpu-generic.mk`
- `android/graphics/host-gpu-intel.mk`
- `android/royd/device/royd/sepolicy/vendor/file_contexts`
- `android/royd/device/royd/vintf/manifest-15.xml`
- `android/royd/vendor/royd/bin/royd-graphics-setup`
- `android/scripts/install-royd.sh`
- `android/scripts/graphics-contract-test.sh`
- `android/scripts/hal-contract-test.sh`
- `android/scripts/hal-profile-test.sh`
- `android/scripts/version-test.sh`
- `android/scripts/vintf-contract-test.sh`
- `android/versions/15.env`
- `docs/graphics.md`
- `docs/hal-profiles.md`
- `docs/hardware-contract.md`
- `docs/host-gpu.md`
- `docs/development-notes.md`

Validation actually performed:

- Verified the frozen composer3 V3 `IComposer` and `IComposerClient` method surface and callback contract from AOSP source.
- Verified VTS behaviour for unsupported brightness, doze/suspend modes, overlay support, ALLM, boot-display configuration, display identification, and invalid saturation-matrix dataspaces.
- `android/scripts/version-test.sh`, `graphics-contract-test.sh`, `vintf-contract-test.sh`, `hal-contract-test.sh`, `hal-profile-test.sh`, `config-check-test.sh`, and `aosp-shell-test.sh` passed after the final implementation changes.
- Full canonical `make ci` completed with exit code 0 and `royd lightweight CI passed` on 2026-09-21.
- Repository policy, patch reproducibility, clean-apply comparison, and archive comparison are performed before task artefacts are handed over.
- Roadmap remains 63 checked and 24 open. Task 043 closes no roadmap checkbox because clean AOSP compilation, normal VINTF, composer VTS, real SurfaceFlinger boot, and display behaviour still require external evidence.

External validation still required:

- A real `android-15.0.0_r36` build must compile and link the allocator, mapper, and composer3 service against the exact generated AIDL and command-buffer headers.
- Normal `check_vintf` must accept the complete Android 15 product without lowering FCM or disabling validation.
- Composer3 VTS must run against the built image. Static source checks do not establish VTS conformance.
- Real boot validation must confirm SurfaceFlinger discovers the composer3 service, accepts the fixed display, performs client composition, and remains stable under vsync/present traffic.
- Real runtime validation must confirm useful graphical output/capture semantics. The composer intentionally performs no physical scan-out.

Unresolved failures or questions:

- No real Android 15 build has yet tested the new modern graphics family. Compile or Soong integration failures may still exist.
- Present-fence behaviour is deliberately minimal and needs real SurfaceFlinger/VTS evidence before it can be treated as qualified.
- Android 15 host-GPU allocation still needs a separate modern allocator/mapper integration decision and real DRM-host evidence.
- Android 16 and 17 remain on their configured legacy graphics metadata pending branch-specific contract research.
- Userfaultfd GC selection for a host-kernel runtime remains a separate host/runtime validation question.

Recommended next task: task 044 should perform a bounded Android 15 normal-VINTF and build-readiness review. It should statically inspect the exact pinned Soong module names, generated AIDL signatures, service/SELinux wiring, product package resolution, and normal VINTF contracts, adding regression checks where practical. Do not start Android 16/17 migration or host-GPU redesign in that task.

Paid external build recommendation: keep the build host off until task 044 is complete. After that review, a fresh Android 15 software build should be the next source of evidence.

Exact Android 15 command for the next external build:

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

Expected evidence to return: `.work/logs/android15-x86_64-standard-graphical-software.log`, or the first genuine failure with approximately 100 surrounding lines. Useful success evidence is successful Soong compilation/linking and vendor installation of `android.hardware.graphics.allocator-service.royd`, `mapper.royd`, and `android.hardware.graphics.composer3-service.royd`, followed by normal `check_vintf` progressing without allocator/mapper/composer interface errors. Do not bypass any VINTF failure.
