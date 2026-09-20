# Low-memory profile

royd treats low memory as a measured product property, not as a fixed RAM claim. The initial Android configuration enables supported low-RAM behaviour and keeps more aggressive optimisation tied to repeatable measurements.

## Android properties

The royd vendor product currently sets:

```properties
ro.config.low_ram=true
ro.lmk.use_psi=true
ro.lmk.use_minfree_levels=false
```

`ro.config.low_ram` enables Android low-memory behaviour. PSI remains the preferred `lmkd` pressure signal, and the legacy minfree-level strategy remains disabled.

royd does not currently override detailed `lmkd` thresholds because those values need to be tested against container memory limits and representative workloads.

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

Build-time slimming is now isolated behind explicit `standard` and `minimal` Android image profiles. The first minimal profile removes only a small set of optional packages so its memory and image-size effects can be measured without conflating them with more aggressive framework changes. See [`image-profiles.md`](image-profiles.md).

## Next optimisation work

The minimal profile should be validated on reference hosts before additional services or packages are removed. Detailed `lmkd` tuning, process limits, rendering changes, and hard defaults should follow the same measurement-first rule.
