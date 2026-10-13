# Low-memory profile

royd treats low memory as a measured product property, not as a fixed RAM claim or a universal runtime mode. The initial Android configuration enables supported low-RAM behaviour and keeps more aggressive optimisation tied to repeatable measurements.

## Android properties

The royd vendor product currently sets:

```properties
ro.config.low_ram=true
ro.lmk.use_psi=true
ro.lmk.use_minfree_levels=false
```

`ro.config.low_ram` enables Android low-memory behaviour. PSI remains the preferred `lmkd` pressure signal, and the legacy minfree-level strategy remains disabled.

royd does not currently override detailed `lmkd` thresholds because those values need to be tested against container memory limits and representative workloads.

The Android 15 image defaults to this baseline. Set `ROYD_RESOURCE_PROFILE=performance` to select normal-RAM framework behaviour and AOSP's 2 GB phone Dalvik heap before init publishes boot properties. The same image supports both modes, and runtime and benchmark evidence records the selection. Automatic selection based on the container memory limit remains future work, as do measured process-retention and detailed `lmkd` policies.

## Display profiles

The default profile is 540 x 960 at 240 dpi and 30 fps. The repository also includes compact and tablet profiles so display cost can be compared without rebuilding Android.

See [`profiles.md`](profiles.md) for the exact values and usage.

## Measurement tools

For an already running container:

```sh
make memory-report
```

For disposable candidate memory limits:

```sh
make memory-sweep
```

The sweep defaults to several candidate limits between 512 MB and 1 GB. They are deliberately labelled as candidates rather than supported configurations. See [`benchmarking.md`](benchmarking.md) for the measurement contract.

## Android image profiles

Build-time slimming is isolated behind explicit `standard` and `minimal` Android image profiles. The minimal profile now uses a version-family package policy with a protected core package guard. The exact removal list and its SHA-256 are embedded in each image so memory and image-size comparisons remain attributable as the policy evolves. See [`image-profiles.md`](image-profiles.md).

## High-resource performance

Large-memory instances can opt into normal-RAM Android 15 behaviour and a larger standard AOSP Dalvik heap without rebuilding the image. Comparative Dalvik and `lmkd` measurements, higher display refresh experiments, and a qualified host-GPU path remain outstanding. Performance mode must not silently replace the low-memory and multi-instance default.

Leading Android container performance is a comparison target rather than an assumed property. Any comparison must use the same host hardware, Android release and architecture, renderer, display size and frame rate, CPU and memory limits, storage state, scrcpy settings and named workload. Boot completion alone is not a performance result.

## Next optimisation work

The expanded minimal profile should be validated on reference hosts before additional services or packages are removed. The performance resource profile must be compared with the low-memory baseline before tuning `lmkd`, process limits, rendering policy, or defaults. The memory sweep enforces named workload and resource-profile provenance for command-driven workloads.
