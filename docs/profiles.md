# Runtime profiles

royd keeps display tuning separate from Android image identity. A runtime profile is a small set of display arguments passed to the container at boot.

## Included profiles

| Profile | Resolution | DPI | FPS | Purpose |
| --- | --- | ---: | ---: | --- |
| `default` | 540 x 960 | 240 | 30 | General development baseline |
| `compact` | 360 x 640 | 160 | 30 | Lower display cost for comparative measurements |
| `headless` | 64 x 64 | 72 | 5 | Default for the headless HAL profile |
| `tablet` | 720 x 1280 | 320 | 30 | Larger application test surface |

Profiles do not imply a supported RAM minimum. They only change display-related Android boot arguments. When `ROYD_PROFILE` is unset, graphical images use `default` and headless images use `headless`.

Use a profile with the smoke tests:

```sh
ROYD_PROFILE=compact make runtime-smoke-test
ROYD_PROFILE=compact make runtime-multi-test
```

Inspect the arguments for a profile directly with:

```sh
./runtime/scripts/profile.sh compact
```

Compose remains environment-driven rather than profile-name driven. Copy the values from a profile into `runtime/.env` when you want Compose to use the same display settings.
