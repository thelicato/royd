# AGENTS.md

## Project overview

The project is named **royd**.

royd is an Android runtime designed specifically for OCI containers. Its main goals are:

- Run Android directly in Docker, Podman, or another OCI-compatible runtime without QEMU or a guest kernel.
- Keep the default user experience as simple as `docker run` or `docker compose up`.
- Minimise host-specific setup by relying on modern Linux kernel facilities such as binderfs.
- Reduce Android memory usage so that useful Android instances can run on low-RAM hosts and many instances can share one host efficiently.
- Keep Android container images usable without any royd-specific host binary.
- Offer an optional Go CLI for convenience, diagnostics, and instance management without making it a runtime requirement.

royd is an independent AOSP-based implementation. Prior art is credited in `docs/acknowledgements.md`. External Android container integrations must not be build, source, runtime, image, manifest, patch, device-tree, or vendor-tree dependencies. royd should not depend on QEMU-based optimisation techniques.

## Core architecture

The OCI image is the primary product. A user must be able to run royd directly with Docker or Compose without installing a royd daemon, launcher, or host helper.

The intended runtime model is:

```text
Linux host kernel
  -> Docker / Podman / OCI runtime
    -> royd container
      -> private mount namespace
      -> private binderfs instance
      -> Android init as PID 1
      -> Android userspace
```

The container should create and manage its own binderfs instance where possible. Android should see the conventional Binder device paths:

```text
/dev/binder
/dev/hwbinder
/dev/vndbinder
```

The implementation should hide binderfs details from Android framework components and from the user.

royd must prefer modern Android and Linux interfaces. In particular:

- Prefer binderfs over statically pre-allocating many host Binder devices.
- Prefer `memfd` over ashmem.
- Prefer cgroup v2-aware memory management.
- Prefer PSI-aware `lmkd` behaviour.
- Avoid DKMS or kernel module compilation as part of the normal runtime path.
- Avoid requiring KVM or QEMU.

A host kernel without the required Binder support may be unsupported. Failure in that case should be immediate and clearly explained in container logs.

## Container behaviour

The expected primary interfaces are similar to:

```sh
docker run --privileged -v android-data:/data -p 5555:5555 ghcr.io/<owner>/royd:<tag>
```

and:

```sh
docker compose up -d
```

The exact image name and final runtime flags may change as implementation work progresses.

Android `/init` should remain PID 1 unless there is a strong technical reason to change this.

Container stdout and stderr should expose Android logs so that:

```sh
docker logs -f <container>
```

behaves like a useful `logcat` stream by default. Normal `adb logcat` access must continue to work independently.

Startup diagnostics should also be written to container logs. They should clearly report relevant host capabilities such as Binder support, binderfs setup, cgroup mode, graphics mode, and fatal compatibility problems.

## Android image goals

The Android image should be built for container workloads rather than treated as a stock emulator image with runtime debloating layered on top.

Where practical, unnecessary packages and services should be removed at build time instead of disabled after boot.

Areas to investigate include:

- `ro.config.low_ram=true` and related framework behaviour.
- PSI-based `lmkd` configuration.
- Cached and background process limits.
- Reduced display resolution and refresh rate profiles.
- Optional host GPU acceleration through `/dev/dri`.
- Efficient software rendering for hosts without GPU access.
- Removal or optionalisation of telephony, Bluetooth, NFC, printing, wallpapers, setup flows, camera support, location services, media components, and other features not required by a given image profile.
- Sharing immutable OCI layers and Linux page cache between instances.
- Efficient per-instance `/data` storage.

Memory targets must be benchmark-driven. Do not claim that a given RAM size is reliable until it has been tested with a defined workload.

## Optional CLI

An optional CLI named `royd` may be implemented in Go.

The CLI is a convenience layer only. Removing it must not remove any core runtime capability.

Possible commands include:

```text
royd doctor
royd run
royd ps
royd shell
royd logs
royd stop
royd rm
```

The CLI may help with:

- Host capability checks.
- Generating or executing Docker commands.
- Instance lifecycle management.
- ADB access.
- Log access.
- Multi-instance workflows.

Do not introduce a mandatory royd daemon or background host service without a compelling reason.

## Security direction

Initial development may use `--privileged` to establish a working baseline.

After the architecture is functional, investigate the minimum capabilities, devices, mounts, namespaces, and security policy required to remove or reduce privileged operation.

Do not allow security-hardening work to obscure or block early architectural validation, but document temporary privileges clearly.

## Development rules

These rules apply to every session and every contribution:

- Use British English in documentation, comments, user-facing text, and commit-related suggestions unless an external API or upstream project requires exact wording.
- Do not use em dashes. Use normal dashes, commas, colons, semicolons, or separate sentences instead.
- Do not add useless blank lines or excessive vertical spacing in documentation.
- Keep documentation concise, technical, and maintainable.
- Prefer simple designs with explicit dependencies over hidden host mutation.
- The OCI image is the primary interface. The optional CLI must never become mandatory for normal operation.
- Prefer capability detection over Linux distribution detection.
- Prefer upstream Linux and Android mechanisms over distro-specific workarounds.
- Avoid adding legacy compatibility code unless there is a demonstrated need and the maintenance cost is justified.
- Keep changes scoped to one meaningful task at a time. Prefer a cohesive small milestone over micro-tasks that change only one trivial file, while keeping each task reviewable and independently revertible.
- Stop after completing each atomic task. Summarise what changed, list the remaining roadmap tasks as a numbered list, and suggest one Conventional Commit message. Do not continue to the next task until the user asks to proceed.
- Use Conventional Commits for commit suggestions, for example `docs: add project architecture guidelines`, `feat: add binderfs bootstrap`, or `test: add host capability checks`.
- Do not commit generated artefacts, build outputs, caches, credentials, secrets, or machine-specific files unless they are intentionally part of the project.
- Treat the work as a repository, not as isolated files. Preserve the full repository structure across tasks.
- After every completed atomic task, provide a ZIP archive containing the complete repository state and a `.patch` file containing only the changes made by that atomic task.
- The patch must be suitable for review and, where practical, application with standard Git tooling. Generate it relative to the repository state before the current atomic task.
- When changing runtime behaviour, add or update tests or reproducible validation steps where practical.
- When assumptions about Linux kernel or Android behaviour matter, prefer verifying them against current upstream documentation or source before implementation.

## Working style for future sessions

At the start of a new session:

1. Read this file before making changes.
2. Inspect the repository state and recent relevant files.
3. Identify the next useful atomic task from the user's request.
4. Complete only that task.
5. Run relevant checks or tests.
6. Package the complete repository as a ZIP and generate a patch containing only the current task's changes.
7. Summarise the result, list the remaining roadmap tasks as a numbered list, and suggest a Conventional Commit message.
8. Stop and wait for the user before starting another task.

When a design decision changes, update this file if the decision is important enough that a future session should know it.

## Current decisions

- Pinned Android versions: 8.0 through 17. Android 15 remains the default baseline until every version completes clean build and boot validation.
- CI model: `make ci` is the canonical lightweight repository suite. `make android-matrix-report` distinguishes configured Android metadata from resolved checks against locally synced AOSP trees. Missing trees are informational unless strict matrix mode is requested.

The following decisions are currently agreed:

- Project name: `royd`.
- Primary runtime: OCI container image.
- Primary user experience: plain Docker or Docker Compose.
- No mandatory royd host binary, daemon, or bootstrap service.
- Optional CLI: Go. Keep the implementation small, local-first, transparent about Docker operations, and limited to convenience commands and lightweight host checks until runtime validation justifies more automation.
- Binder strategy: prefer a private binderfs instance managed from inside each container where the host kernel and container runtime permit it. The Binder allocation helper is implemented and built from this repository.
- Android logging: expose `logcat` through container stdout and stderr so `docker logs` is useful by default.
- ADB: development images expose `adbd` over TCP port 5555 with authentication disabled for local container workflows. Keep the host publication loopback-only by default and treat remote exposure as unsafe unless explicitly secured.
- Container health: imported OCI images include a health check that requires Android boot completion, running `adbd`, ADB TCP configuration, and Binder device readiness.
- Android init should remain PID 1 unless implementation evidence shows a better approach.
- Privileged containers remain the development baseline. An experimental restricted mode is maintained for evidence-driven capability reduction and must not be described as a supported minimum until reference-host tests pass.
- Low memory is a core engineering goal but not part of the project name or a licence to remove functionality without defined image profiles and tests.
- Android source policy: plain AOSP only. Android 8.0 through 17 are pinned, with Android 15 as the default baseline until all versions complete clean build and boot validation.
- Initial build architecture targets: `x86_64` and `arm64`, using repository-owned `royd_x86_64` and `royd_arm64` products with the AOSP `userdebug` variant.
- Android dependency policy: the normal build may fetch the pinned AOSP manifest only. All royd-specific device definitions, vendor code, helper binaries, init rules, image profiles, and AOSP patches must live in this repository.
- Android customisation strategy: copy `android/royd/device/royd` and `android/royd/vendor/royd` into the synchronised AOSP tree, then apply only repository-owned patches from `android/patches`.
- Android compatibility families: `legacy` for 8.0/8.1/9, `transitional` for 10, and `modern` for 11+. Version metadata selects the builder, partition set, product fragment, board fragment, and vendor properties.
- Legacy Android builder: Android 8.0 through 10 use an Ubuntu 18.04 builder with OpenJDK 8 and Python 2/3; Android 11 onward uses the modern builder.
- Legacy memory policy: Android 8.0 through 10 install a repository-owned `libcutils` ashmem API backend backed by sealed memfds. Never require the removed host `ashmem_linux` module. Keep these releases in configured status until direct-ioctl compatibility and real workloads are validated.
- Runtime image assembly: package AOSP `ramdisk.img` plus required `system`, `vendor`, `system_ext`, and `product` images into one OCI root filesystem, with optional `odm`, and keep Android `/init` as the OCI entrypoint.
- Initial low-memory baseline: `ro.config.low_ram=true`, PSI-based `lmkd`, legacy minfree levels disabled, and a 540 x 960 at 240 dpi and 30 fps default display profile.
- Software graphics baseline: SwiftShader plus repository-owned `gralloc.royd`, `hwcomposer.default`, and the AOSP composer service selected per Android generation. Host GPU mode is not yet supported.
- Android image profiles: `standard` preserves the upstream package set; `minimal` conservatively removes `BasicDreams`, `EasterEgg`, `PrintRecommendationService`, and `PrintSpooler`. Profile changes run `installclean` before rebuilding.
- Android image profile tags: standard imports as `royd:dev`; minimal imports as `royd:dev-minimal` by default.
- Runtime display profiles: `default` (540 x 960, 240 dpi, 30 fps), `compact` (360 x 640, 160 dpi, 30 fps), and `tablet` (720 x 1280, 320 dpi, 30 fps). Profiles do not imply supported memory minimums.
- Memory benchmarking: use disposable container sweeps with fresh `/data`, equal memory and swap limits, normal boot assertions, and Markdown reports before making RAM claims.
- Memory claims must be based on the repository measurement workflow and a documented workload.
- Project logo: keep the canonical SVG at repository root as `logo.svg` and reference it from the main README, with the logo centred and the project name shown below it.
- Runtime validation: keep boot smoke tests usable with Docker alone and commands available inside the Android container; ADB must not be required for basic validation.
- OCI image identity: use canonical tags derived from AOSP ref, image profile, HAL profile, and architecture; keep short `royd:dev*` tags only as local aliases.
- Packaged images: include immutable `/royd-release` metadata and verify the sidecar archive digest before import.
- Android build contract: keep no-kernel/no-bootloader mode, required ext4 partition images, and container copy-out paths explicit in `android/build-contract.env`; validate them statically and against resolved AOSP build variables before full compilation.
- Product composition: do not inherit AOSP emulator product definitions or `emulator_vendor.mk`; compose royd products from explicit AOSP userspace building blocks and repository-owned x86_64 and arm64 board configuration.
- Host hardware contract: Linux plus binderfs are hard runtime requirements; cgroup v2 and memory PSI are preferred; the first graphics baseline is AOSP SwiftShader and does not require `/dev/dri`.
- Graphics direction: do not claim host GPU acceleration until royd owns and validates the full allocator, composer, device exposure, permissions, and fallback path.
- HAL profiles: `graphical` is the default interactive software-rendered profile; `headless` is server-oriented but still retains the minimum allocator/composer/SurfaceFlinger path required for normal Android boot.
- AOSP build primitives remain upstream dependencies, but royd owns its product and board definitions and must not inherit emulator product bundles.
- Reference-host evidence: use the repository report workflow to record kernel, Docker, Binder, cgroup, and smoke-test results before making host compatibility claims.
- Local Compose workflow: keep `runtime/compose.yaml` configurable through `runtime/.env`, with Make targets remaining thin wrappers over Docker Compose.
- Runtime security modes: `privileged` is the current baseline; `experimental` removes `--privileged` and tests explicit capabilities through the same smoke, benchmark, report, Compose, and CLI workflows.


Android version validation is an explicit remaining project task until every pinned version passes clean x86_64 and arm64 builds, OCI packaging, and runtime smoke tests.
