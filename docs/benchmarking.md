# Memory benchmarking

royd does not treat a successful boot at one memory limit as a supported minimum. Memory claims must include the exact image identity, Android image profile and policy digest, host, HAL and graphics backend, display profile, Android workload, and container constraints used for the measurement.

## Single-container snapshot

For an already running container:

```sh
make memory-report
```

This records Docker memory usage, the configured memory limit, Android low-memory properties, Android aggregate memory information, and the largest resident processes.

## Candidate memory sweep

The repository can boot fresh disposable containers across a set of candidate memory limits:

```sh
make memory-sweep
```

The default candidates are:

```text
512m 640m 768m 896m 1024m
```

These values are test candidates only. They are not compatibility claims.

Override the candidates, display profile, settle time, or output path with environment variables:

```sh
ROYD_PROFILE=compact \
ROYD_MEMORY_LIMITS="512m 640m 768m" \
ROYD_MEMORY_SETTLE=15 \
ROYD_MEMORY_SWEEP_OUTPUT=memory-sweep.md \
make memory-sweep
```

Each candidate receives a fresh `/data` volume. Docker memory and swap are constrained to the same value so the result is easier to compare between runs. A candidate is marked passed only after Android reports boot completion, the normal runtime assertions succeed, the requested workload succeeds, and the settle interval completes.

The default workload is named `boot-idle` and performs no command after boot. A representative workload must have both a stable name and an explicit command, for example:

```sh
ROYD_MEMORY_WORKLOAD=package-list \
ROYD_MEMORY_WORKLOAD_COMMAND='pm list packages >/dev/null' \
ROYD_MEMORY_SWEEP_OUTPUT=memory-package-list.md \
make memory-sweep
```

A custom command without a workload name, or a workload name without a command, is rejected so a report cannot silently lose workload provenance.

## Interpreting results

A passing row means that the named workload completed under that exact configuration. It does not prove stability under application workloads. A failing row may be caused by the memory limit, Android boot failure, runtime assertions, or another host issue.

Before publishing a minimum RAM figure, repeat the test across multiple boots and add a representative application workload. Record the reference-host report alongside the memory sweep.

Every generated sweep includes the image ID, Android version and AOSP ref, Android image profile, package-policy identifier and SHA-256, HAL profile, graphics backend, exact display dimensions/density/frame rate, security mode, workload name and command, boot timeout, and settle interval. Figures without that provenance should not be published as royd memory results.


## Android image profile comparison

After building and importing both standard and minimal images, compare them under the same display profile and candidate memory limits:

```sh
ROYD_IMAGE_PROFILE_SWEEP_OUTPUT=image-profile-sweep.md \
make image-profile-sweep
```

The comparison records Docker image size and embeds the memory sweep for each Android image profile. Passing containers also report the profile property and installed package count. This makes build-time package removal measurable without changing the runtime display or memory-test methodology.
