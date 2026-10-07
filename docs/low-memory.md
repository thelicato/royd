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

The current Android 15 image always enables this baseline, even when the container has ample memory. That is safe for current compatibility work but is not the final performance policy. A future explicit or automatically selected resource profile should use the container memory limit, not total host RAM, to choose normal-RAM framework behaviour, an appropriate Dalvik heap profile and measured process-retention policy. The selection must be recorded in image and runtime evidence.

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

Large-memory instances should be able to trade memory efficiency for responsiveness and sustained application performance. That work includes a normal-RAM Android 15 profile, measured Dalvik and `lmkd` policies, higher display refresh options, and a qualified host-GPU path. It must not silently weaken low-memory or multi-instance behaviour.

Leading Android container performance is a comparison target rather than an assumed property. Any comparison must use the same host hardware, Android release and architecture, renderer, display size and frame rate, CPU and memory limits, storage state, scrcpy settings and named workload. Boot completion alone is not a performance result.

## Next optimisation work

The expanded minimal profile should be validated on reference hosts before additional services or packages are removed. The high-resource profile must then be implemented and compared with the low-memory baseline. Detailed `lmkd` tuning, process limits, rendering changes, and hard defaults should follow the same measurement-first rule. The memory sweep enforces named workload provenance for any command-driven workload.
