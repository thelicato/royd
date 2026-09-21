# Development handoff notes

## Task 042 complete

Problem addressed: replace Android 15's legacy gralloc0 allocator contract with the smallest repository-owned modern software allocator/mapper foundation required by the pinned `android-15.0.0_r36` graphics contracts. Composer3 is deliberately deferred.

Important evidence and changes:

- Android 15 FCM `202404` requires AIDL `android.hardware.graphics.allocator` version 1-2 and AIDL composer3. The exact Android 15 stable-C mapper documentation defines mapper V5 as the allocator-V2 companion interface.
- Android 15 now selects `ANDROID_GRAPHICS_ALLOCATOR=aidl2-stablec5-memfd` and `ANDROID_GRAPHICS_MAPPER=stablec5-royd`. Android 14 and the other pinned versions retain their previous allocator selection until separately researched and validated.
- Added a repository-owned AIDL allocator V2 service. It allocates anonymous memfd-backed buffers, rejects protected and unimplemented usage contracts, exposes `getIMapperLibrarySuffix()`, and keeps reserved-region metadata in the shared allocation.
- Added a repository-owned stable-C mapper V5 library with import/free, CPU lock/unlock, transport sizing, reserved-region access, standard metadata, required mutable metadata, and mapper V5 provider callbacks. It exports both `ANDROID_HAL_STABLEC_VERSION` from the upstream implementation documentation and `ANDROID_HAL_MAPPER_VERSION`, which the exact Android 15 mapper VTS resolves.
- The allocator supports the linear software formats currently implemented by royd plus YV12. YV12 follows the Android format contract: even dimensions, Y stride aligned to 16 pixels, chroma stride aligned to 16 pixels, Y/Cr/Cb planes, 4:2:0 subsampling, and DRM `YVU420` metadata.
- Android 15's device manifest now truthfully declares allocator AIDL V2 and native mapper 5.0. It still declares no graphics composer because the repository does not yet implement composer3.
- Added the `mapper/royd` system-ext service-context label required for stable-C mapper discovery. The allocator uses the canonical Android allocator service executable name.
- The software graphics product packages the new allocator/mapper only for versions selecting the modern allocator. Legacy versions keep `gralloc.royd`.
- No emulator, goldfish, ranchu, Cuttlefish runtime, QEMU, AOSP patch, VINTF bypass, or generated emergency manifest dependency was introduced.

Files/interfaces changed:

- `android/graphics/allocator-aidl2/Android.bp`
- `android/graphics/allocator-aidl2/allocator/Allocator.cpp`
- `android/graphics/allocator-aidl2/allocator/Allocator.h`
- `android/graphics/allocator-aidl2/allocator/allocator.rc`
- `android/graphics/allocator-aidl2/allocator/main.cpp`
- `android/graphics/allocator-aidl2/common/royd_buffer.h`
- `android/graphics/allocator-aidl2/mapper/Mapper.cpp`
- `android/graphics/software.mk`
- `android/royd/device/royd/sepolicy/system_ext/private/service_contexts`
- `android/royd/device/royd/vintf/manifest-15.xml`
- `android/scripts/graphics-contract-test.sh`
- `android/scripts/install-royd.sh`
- `android/scripts/version-test.sh`
- `android/scripts/vintf-contract-test.sh`
- `android/versions/15.env`
- `docs/development-notes.md`

Validation actually performed:

- Verified the exact `android-15.0.0_r36` FCM `202404` matrix requires allocator AIDL 1-2 and composer3 version 3.
- Verified the exact Android 15 stable-C mapper provider and metadata helper interfaces used by the implementation.
- Verified the exact Android 15 mapper VTS resolves `ANDROID_HAL_MAPPER_VERSION`, requires YV12 allocation/locking, checks Y/Cr/Cb plane metadata, and expects `DRM_FORMAT_YVU420`.
- `android/scripts/version-test.sh`, `graphics-contract-test.sh`, `vintf-contract-test.sh`, `graphics-backend-test.sh`, `contract-test.sh`, `config-check-test.sh`, and `aosp-shell-test.sh` passed.
- Full `make ci` completed with exit code 0 on 2026-09-21 after the final task 042 implementation changes. A later rerun after editing only this handoff file was terminated by the execution environment during `config-check-test.sh`; it reported no test failure before termination. Final targeted graphics/VINTF/version tests and repository policy scans passed after the notes edit.
- Patch reproducibility checks are performed before the task artefacts are handed over.
- Roadmap remains 63 checked and 24 open. Task 042 closes no roadmap checkbox because clean AOSP compilation, VINTF compatibility, VTS, and runtime behaviour still require external evidence.

External validation still required:

- A real `android-15.0.0_r36` build must compile the new allocator and mapper against the exact generated AIDL/common headers and Soong modules.
- Android 15 mapper and allocator VTS must run against the built image before the implementation can be treated as contract-qualified.
- Real runtime validation must confirm memfd allocation, CPU mapping, SurfaceFlinger use, and memory behaviour. Static tests do not establish those properties.
- Normal VINTF cannot pass yet because Android 15 FCM `202404` requires composer3 and royd still packages the legacy composer 2.4 path.

Unresolved failures or questions:

- Android 15 still selects `ANDROID_GRAPHICS_COMPOSER=2.4`; the exact FCM requires `android.hardware.graphics.composer3` version 3. This is the next known build/VINTF blocker.
- Host-GPU backends remain experimental and have not yet been migrated or qualified against the Android 15 allocator/mapper family. Task 042 implements the portable software path only.
- The exact modern graphics-family boundary for Android 16 and 17 remains deliberately unchanged pending branch-specific research and real-build evidence.
- Userfaultfd GC selection for a host-kernel runtime remains a separate host/runtime validation question.

Recommended next task: task 043 should implement the smallest repository-owned Android 15 composer3 service required by FCM `202404`, oriented around client composition so SurfaceFlinger/RenderEngine remains responsible for software composition. Do not mix Android 16/17 migration or host-GPU redesign into that task.

Paid external build recommendation: keep the build host off until task 043 and a subsequent bounded normal-VINTF/build-readiness review are complete. Composer3 is a known mandatory Android 15 contract, so a full build now is still expected to stop before yielding enough new evidence to justify the cost.

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

Expected evidence to return: `.work/logs/android15-x86_64-standard-graphical-software.log`, or the first genuine failure with approximately 100 surrounding lines. For task 042 specifically, useful evidence is successful Soong compilation/linking of `android.hardware.graphics.allocator-service.royd` and `mapper.royd`, successful vendor installation of those modules, and absence of allocator/mapper VINTF errors. A composer3 VINTF failure remains expected until task 043 and must not be bypassed.
