# Runtime profiles

royd keeps display tuning and resource tuning separate from Android image identity. Both are selected through validated arguments passed to the container before Android init starts.

## Included profiles

| Profile | Resolution | DPI | FPS | Purpose |
| --- | --- | ---: | ---: | --- |
| `default` | 540 x 960 | 240 | 30 | General development baseline |
| `compact` | 360 x 640 | 160 | 30 | Lower display cost for comparative measurements |
| `headless` | 64 x 64 | 72 | 5 | Default for the headless HAL profile |
| `tablet` | 720 x 1280 | 320 | 30 | Larger application test surface |

Display profiles do not imply a supported RAM minimum. When `ROYD_PROFILE` is unset, graphical images use `default` and headless images use `headless`.

## Resource profiles

| Profile | Framework mode | Dalvik heap | Purpose |
| --- | --- | --- | --- |
| `low-memory` | Low RAM | 5 MB start, 48 MB growth limit, 128 MB maximum | Default compatibility and multi-instance baseline |
| `performance` | Normal RAM | 8 MB start, 192 MB growth limit, 512 MB maximum | Android 15 high-resource measurement candidate |

The performance values are AOSP's standard 2 GB phone heap policy. The mode is opt-in and is not a performance claim. It must be benchmarked against `low-memory` with identical container limits, display settings, renderer, image state and workload. Android versions other than 15 reject performance mode until they are built and validated with the same early-property mechanism.

Use a profile with the smoke tests:

```sh
ROYD_PROFILE=compact make runtime-smoke-test
ROYD_PROFILE=compact make runtime-multi-test
ROYD_RESOURCE_PROFILE=performance make runtime-smoke-test
```

Inspect the arguments for a profile directly with:

```sh
./runtime/scripts/profile.sh compact
./runtime/scripts/resource-profile.sh performance
```

Compose remains environment-driven. Copy display values from a profile into `runtime/.env`, and set `ROYD_RESOURCE_PROFILE` independently when selecting resource behaviour.
