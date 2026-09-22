# Development handoff notes

## Task 044 complete

Problem addressed: statically review Android 15 normal-VINTF and build integration against the exact `android-15.0.0_r36` contracts before paying for another full AOSP build.

Important evidence and changes:

- In `android-15.0.0_r36`, `android.hardware.graphics.composer3` has frozen versions 1 through 3, while AOSP's current composer3 NDK defaults link the unfrozen V4 interface. The task-043 service used those current defaults but implemented only the frozen V3 client method surface. That was a statically demonstrable compile-time mismatch.
- The Android 15 composer now builds as `aidl4-client` from `android/graphics/composer-aidl4` and implements the V4 additions `getMaxLayerPictureProfiles`, `startHdcpNegotiation`, and `getLuts`. royd advertises none of the associated optional capabilities, so those methods reject supported-display probes as unsupported.
- The repository source VINTF manifest now declares composer3 version 4 because that is the interface used to build the service. Android 15 stable-AIDL release handling rewrites an unfrozen manifest version to the latest frozen version when `RELEASE_AIDL_USE_UNFROZEN=false`; the Android 15 framework compatibility matrix still requires the frozen composer3 V3 launch contract.
- Added a dedicated Android 15 build-readiness contract test covering the pinned tag/release, current composer ABI, V4-only methods, source-manifest versions, module/install/init paths, mapper instance, SELinux labels, product selection, kernel-less OTA VINTF setting, and continued normal VINTF enforcement.
- Allocator V2 and stable-C mapper V5 integration remains unchanged. Composer client-composition behaviour remains unchanged except for satisfying the current V4 source ABI.
- No AOSP patching, VINTF bypass, emergency manifest generation, emulator runtime dependency, or command spoofing was added.

Files/interfaces changed:

- `AGENTS.md`
- `Makefile`
- `android/graphics/composer-aidl4/` (current V4 source ABI)
- `android/graphics/software.mk`
- `android/graphics/host-gpu-generic.mk`
- `android/graphics/host-gpu-intel.mk`
- `android/royd/device/royd/vintf/manifest-15.xml`
- `android/royd/vendor/royd/bin/royd-graphics-setup`
- `android/scripts/android15-build-readiness-test.sh`
- `android/scripts/graphics-contract-test.sh`
- `android/scripts/install-royd.sh`
- `android/scripts/version-test.sh`
- `android/scripts/vintf-contract-test.sh`
- `android/versions/15.env`
- `docs/graphics.md`
- `docs/hal-profiles.md`
- `docs/hardware-contract.md`
- `docs/host-gpu.md`
- `docs/development-notes.md`
- `scripts/ci.sh`

Validation actually performed:

- Checked the exact `android-15.0.0_r36` AOSP composer3 Soong defaults and AIDL API snapshots: current composer3 is V4, while V1 through V3 are frozen.
- Checked Android stable-AIDL release documentation for Android 15 manifest rewriting and unfrozen-interface fallback behaviour.
- `android15-build-readiness-test.sh`, `version-test.sh`, `graphics-contract-test.sh`, `vintf-contract-test.sh`, `hal-contract-test.sh`, `hal-profile-test.sh`, `config-check-test.sh`, and `aosp-shell-test.sh` passed after the implementation changes.
- Full `make ci`, repository policy scans, patch clean-apply comparison, and archive comparison are performed before task artefacts are handed over.
- Roadmap remains 63 checked and 24 open. Task 044 closes no roadmap checkbox because clean AOSP compilation, normal VINTF, VTS, and runtime behaviour still require external evidence.

External validation still required:

- A real `android-15.0.0_r36` x86_64 software build must compile, link, install, and package allocator V2, mapper V5, and the composer3 service against the generated Android 15 interfaces.
- The build must show the resolved release behaviour for `RELEASE_AIDL_USE_UNFROZEN` and normal `check_vintf` must accept the emitted vendor manifest without lowering FCM or disabling validation.
- Allocator, mapper, and composer VTS remain required. Static tests do not establish VTS conformance.
- A real container boot must confirm Android `/init` as PID 1, SurfaceFlinger discovery of composer3, client composition, logcat exposure, Binder isolation, and stable present/vsync behaviour.

Unresolved failures or questions:

- No real AOSP build has yet compiled the modern Android 15 graphics family. Generated-header, Soong, linker, SELinux, or VINTF failures may still appear and must be treated as new evidence rather than bypassed.
- Present-fence behaviour remains deliberately minimal and requires VTS/runtime evidence.
- Android 15 host-GPU allocation is not qualified against the modern allocator/mapper path. Software remains the next build target.
- Android 16 and 17 graphics-family migration remains separate work.
- Userfaultfd GC selection remains a separate host-kernel/runtime validation question.

Recommended next task: use the next real Android 15 software build as task 045 evidence. Do not add another speculative architecture milestone first. Fix the first genuine build failure, if any, as the smallest coherent follow-up.

Exact external build command:

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

Expected evidence to return: `.work/logs/android15-x86_64-standard-graphical-software.log`, or the first genuine failure with approximately 100 surrounding lines. Useful success evidence is compilation/linking and vendor installation of `android.hardware.graphics.allocator-service.royd`, `mapper.royd`, and `android.hardware.graphics.composer3-service.royd`, followed by normal `check_vintf` acceptance. Also return any line showing the resolved `RELEASE_AIDL_USE_UNFROZEN` value if the build log exposes it. Do not bypass a VINTF or SELinux failure.
