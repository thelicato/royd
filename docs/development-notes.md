# Development handoff notes

## Task 039 complete

Problem addressed: fold the bounded real-build fixes from Android 15 bring-up into repository-owned code without carrying forward r13 source rewriting or VINTF bypasses.

Evidence and changes:

- Root-operated hosts previously mirrored UID/GID 0 into the builder image, causing `groupadd --gid 0 builder` to fail. `android/scripts/builder.sh` now selects non-zero builder IDs on host UID 0, defaults to 1000:1000, permits `ROYD_BUILD_UID` and `ROYD_BUILD_GID` overrides, and prepares the mounted work directory for that identity.
- Ubuntu 22.04's packaged Repo launcher rejected `repo init --git-lfs`. `android/scripts/sync.sh` no longer passes that option and retains the existing explicit `repo forall -c 'git lfs pull'` step. Existing `.repo` checkouts are still reused rather than reinitialised.
- AOSP `build/envsetup.sh`, `lunch`, and build functions require Bash and are not compatible with nounset during setup. `android/scripts/config-check.sh` and `android/scripts/build.sh` now use Bash, keep errexit, and disable nounset only after sourcing royd `common.sh`.
- The builder now forwards `JOBS`, `ROYD_CLEAN_BUILD`, `ROYD_ANDROID_VERSION`, `ROYD_ANDROID_PROFILE`, `ROYD_HAL_PROFILE`, and `ROYD_GRAPHICS_BACKEND` into Docker.
- `android/royd/vendor/royd/gralloc/gralloc_royd.cpp` now initialises the const legacy `framebuffer_device_t` geometry/timing fields through typed `const_cast` assignments. This matches the ABI constraint exposed by the real Android 15 compile and avoids dynamically rewriting the source.
- Added focused regression coverage in `android/scripts/sync-contract-test.sh`, `android/scripts/aosp-shell-test.sh`, `android/scripts/builder-family-test.sh`, and `android/scripts/graphics-contract-test.sh`, wired into `make ci`.

Validation performed:

- Focused builder, sync, AOSP shell, and graphics contract tests passed.
- Root-path builder tests ran as UID 0 in the sandbox with Docker mocked. They verified default non-root identity selection, explicit non-zero UID/GID overrides, rejection of UID/GID 0, and environment forwarding. They do not prove a real Docker image build on a cloud host.
- Full `make ci` completed with exit code 0 on 2026-09-21, including all existing runtime contract tests and Go tests.
- Repository scan found no em dash characters.
- Repository scan found no prohibited prior-art name references outside `docs/acknowledgements.md`.
- Roadmap remains 63 checked and 24 open. Task 039 closes no roadmap checkbox because the relevant open items require real AOSP build or runtime evidence.

External validation still required:

- Confirm a real root-operated Ubuntu 22.04 builder can build the Docker builder image without the GID 0 failure.
- Confirm the installed Repo launcher accepts the repository-owned sync command and the partial Android 15 checkout resumes successfully.
- Confirm the Android 15 x86_64 build no longer reports `function: not found`, nounset failures, or const `framebuffer_device_t` assignment errors.
- Normal VINTF validation must remain enabled. The known missing device-manifest and modern graphics/VINTF work is intentionally unresolved by task 039.

Recommended next task: task 040 should add the bounded repository-owned root-level build convenience wrapper and remote-build UX. It should centralise dependency/Docker checks, conservative resumable sync retries, separate sync/build job counts, skip-sync and clean/incremental controls, logging, and artefact reporting without patching AOSP or royd source and without duplicating compatibility policy.

Exact Android 15 host command for task 039 validation, using an existing partial checkout when present:

```sh
cd /root/royd-build/royd
export ROYD_ANDROID_VERSION=15
export ROYD_ANDROID_PROFILE=standard
export ROYD_HAL_PROFILE=graphical
export ROYD_GRAPHICS_BACKEND=software
export ROYD_BUILDER_TTY=never
JOBS=1 make android-sync
JOBS="$(nproc)" make android-config-check
ROYD_CLEAN_BUILD=0 JOBS="$(nproc)" make android-build-x86_64
```

Expected success evidence to return: the builder reports a non-zero UID/GID; `repo init` does not reject `--git-lfs`; config check completes without Bash/nounset errors; the gralloc translation unit compiles past the legacy framebuffer assignments; and the build reaches a later normal-validation failure or completes. If it fails, return the first real error with approximately 100 surrounding log lines plus the builder UID/GID line and `repo --version`. A later missing VINTF manifest or modern graphics compatibility failure is expected to remain possible and belongs to subsequent tasks.
