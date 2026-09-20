# Low-memory profile

royd treats low memory as a measured product property, not as a fixed RAM claim. The initial profile enables Android's supported low-RAM behaviour and reduces default display cost while keeping broader feature removal for later benchmark-driven work.

## Android properties

The royd vendor product currently sets:

```properties
ro.config.low_ram=true
ro.lmk.use_psi=true
ro.lmk.use_minfree_levels=false
```

`ro.config.low_ram` tells Android framework components and `lmkd` to use low-memory behaviour. PSI remains the preferred `lmkd` pressure signal, and the legacy minfree-level strategy remains disabled.

These are deliberately conservative settings. royd does not currently override detailed `lmkd` thresholds because those values need to be tested against container memory limits and representative workloads.

## Display defaults

The imported development image uses this default display profile:

```text
540 x 960
240 dpi
30 fps
```

The smaller framebuffer reduces graphics memory relative to ReDroid's larger default display while remaining practical for application testing. These values are starting defaults, not a claimed optimum.

The essential runtime arguments remain part of the image entrypoint. Display arguments are stored as the image command, so they can be replaced with normal Docker arguments. For example:

```sh
docker run -d --privileged \
  --name royd \
  -v royd-data:/data \
  -p 127.0.0.1:5555:5555 \
  royd:dev \
  androidboot.redroid_width=720 \
  androidboot.redroid_height=1280 \
  androidboot.redroid_dpi=320 \
  androidboot.redroid_fps=30
```

## Memory reports

After the container is booted, collect a repeatable snapshot with:

```sh
make memory-report
```

or for a differently named container:

```sh
./runtime/scripts/memory-report.sh my-container
```

The report records the OCI memory limit and current usage, verifies the Android low-memory properties, prints Android's aggregate memory summary, and lists the largest resident processes.

When comparing changes, use the same Android build, container memory limit, display settings, rendering mode, boot settling time, and workload. Idle figures alone are not sufficient to establish a reliable minimum RAM requirement.

## Next optimisation work

Package and service removal should be introduced as an explicit image profile only after the baseline has been booted and measured. Detailed `lmkd` tuning, process limits, rendering changes, and hard memory limits should follow the same measurement-first rule.
