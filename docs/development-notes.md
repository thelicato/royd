# Development handoff notes

## Task 040 complete

Problem addressed: replace the temporary remote bring-up wrapper with a repository-owned root-level build convenience entry point, while keeping all build policy and implementation in the existing royd scripts and avoiding source mutation or validation bypasses.

Important evidence and changes:

- Added executable `./build.sh` for fresh-host Android build orchestration. It validates Android version, architecture, image profile, HAL profile, and graphics backend through repository-owned metadata and validator scripts.
- The helper checks required host commands and Docker access, defaults AOSP sync concurrency to one job, separates sync and build job counts, retries whole sync attempts while preserving partial `.work/android-src-<version>` state, supports `--skip-sync`, and supports explicit clean or incremental builds.
- A clean build is the helper default. Existing lower-level scripts keep their own defaults and remain authoritative.
- The helper runs repository-owned sync, resolved configuration check, build, package, import, image-tag, and image-alias stages. It writes `.work/logs/android<version>-<arch>-<profile>-<hal>-<graphics>.log` and reports the archive, manifest, canonical image tag, development alias, checksums, and Docker image summary.
- Root-operated hosts rely on the task 039 `android/scripts/builder.sh` non-zero builder identity handling. `build.sh` defaults builder TTY handling to `never` for reliable remote/logged execution and does not spoof `id` or other host commands.
- The helper contains no AOSP patching, royd source rewriting, VINTF enforcement changes, emergency manifest generation, or compatibility matrix duplication.
- Added `scripts/build-helper-test.sh`, `make build-helper-test`, CI integration, and concise build-helper documentation in `README.md` and `docs/building.md`.

Validation actually performed:

- `bash -n build.sh` and `sh -n scripts/build-helper-test.sh` passed.
- `scripts/build-helper-test.sh` passed. It covers help and argument validation, conservative sync retry, preservation/reuse through `--skip-sync`, separate sync/build job forwarding, clean/incremental selection, Android/profile/HAL/graphics forwarding, logging, package/import sequencing, and final artefact paths with mocked external operations.
- The helper regression test also rejects source/VINTF mutation tokens associated with the temporary bring-up wrapper.
- Full `make ci` completed with exit code 0 on 2026-09-21, including all existing Android, runtime, reference-host bundle, and Go tests.
- Roadmap remains 63 checked and 24 open. Task 040 closes no roadmap checkbox because the remaining build-related checkboxes require real AOSP or runtime evidence.

External validation still required:

- Run `./build.sh` on a fresh root-operated Docker build host and confirm Docker builder creation, AOSP sync retry/resume, resolved config check, Android compilation, packaging, and import work without temporary wrapper changes.
- Confirm task 039 fixes remain effective in the real build: no GID 0 builder failure, no unsupported `repo init --git-lfs`, no AOSP envsetup shell/nounset failure, and no const `framebuffer_device_t` assignment failure.
- Normal framework/vendor VINTF validation must remain enabled throughout.

Unresolved failures or questions:

- Android 15 still lacks the permanent kernel-less product/VINTF foundation discovered during the previous real build, including an appropriate device manifest and correct handling of kernel OTA VINTF requirements without inventing a guest kernel or boot image.
- The current Android 15 graphical stack still declares legacy HIDL composer 2.4 and gralloc0-era allocation. Its compatibility with the Android 15 framework matrix is unresolved and must not be bypassed by lowering FCM or disabling VINTF.
- The exact Android-version boundary for the modern allocator/mapper/composer family still requires validation against pinned AOSP contracts.

Recommended next task: task 041 should address only the kernel-less Android product/VINTF foundation and permanent device-manifest wiring, with exact Android 15 contract research as needed. Keep allocator/mapper and composer3 implementation for later bounded tasks unless the pinned contract proves a smaller prerequisite is inseparable.

Exact fresh-host Android 15 command:

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

Expected evidence to return: the `.work/logs/android15-x86_64-standard-graphical-software.log` file or its first real failure with approximately 100 surrounding lines. Success through task 039 defects means a non-zero builder UID/GID, accepted Repo initialisation, successful AOSP envsetup/config-check, and gralloc compilation past the legacy framebuffer assignments. A later missing VINTF manifest, kernel OTA VINTF warning/failure, or graphics composer compatibility failure is expected to remain possible and belongs to task 041 or later.
