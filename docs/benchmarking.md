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
ROYD_RESOURCE_PROFILE=low-memory \
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

Every generated sweep includes the image ID, Android version and AOSP ref, Android image profile, package-policy identifier and SHA-256, HAL profile, graphics backend, resource profile, exact display dimensions/density/frame rate, security mode, workload name and command, boot timeout, and settle interval. Figures without that provenance should not be published as royd memory results.

## Resource-profile comparison

Compare Android 15's low-memory and performance resource profiles from the same image with:

```sh
ROYD_RESOURCE_BENCHMARK_OUTPUT=.work/resource-profile-benchmark.md \
make runtime-resource-profile-benchmark
```

The benchmark alternates profiles for five repetitions by default. Every repetition uses a fresh `/data` volume, four CPUs, a 4 GiB memory and swap limit, the same software renderer and display profile, and the same workload. The workload records boot-to-Home time, five force-stop plus cold Settings launches, Settings `gfxinfo` after controlled scrolling, five core-UI cycles through cold Settings and DocumentsUI launches with scrolling and Home transitions, a three-second software `screenrecord`, cgroup CPU time, settled memory and peak memory. Settings, DocumentsUI and Home are protected by both Android image profiles, so the same workload remains available to standard and minimal images. Summary metrics use the median and show the observed minimum-to-maximum range. The Markdown report is accompanied by raw measurement and phase-labelled per-process RSS TSV files, allowing memory outliers to be investigated without treating summed RSS as cgroup usage.

Override the repetitions or container limits while preserving the paired comparison:

```sh
ROYD_RESOURCE_BENCHMARK_REPETITIONS=10 \
ROYD_RESOURCE_BENCHMARK_APP_CYCLES=10 \
ROYD_RESOURCE_BENCHMARK_CPUS=8 \
ROYD_RESOURCE_BENCHMARK_MEMORY=8g \
ROYD_RESOURCE_BENCHMARK_OUTPUT=.work/resource-profile-benchmark.md \
make runtime-resource-profile-benchmark
```

The recording wall time and output size confirm that the software encoder completed its fixed real-time workload. They are not an unconstrained encoder-throughput score. Treat differences smaller than run-to-run variation as inconclusive, and do not generalise one host's result into a support or performance claim.

## Competitive performance comparison

Performance comparisons against another Android container runtime must control the host, Android version and architecture, renderer, display dimensions and frame rate, CPU and memory limits, storage state, scrcpy codec and bit rate, and application workload. Report at least boot-to-home time, application launch latency, rendered frame timing, encoder throughput, host CPU time, peak and settled memory, and workload success or failure.

The current Android 15 software profile is a portable compatibility baseline. It must not be described as matching a competing runtime until an identical-host comparison demonstrates that result. Software and host-GPU results belong in separate comparison groups. A high-resource royd profile must also be compared with the low-memory profile so increased responsiveness is not mistaken for an uncontrolled memory regression.

### Preliminary Android 15 comparison gate

A preliminary single-host comparison does not require completing the other Android versions, qualifying reduced privileges or eliminating every warning. It requires a frozen, functioning Android 15 baseline and an independently qualified comparator. It is not release acceptance or a support claim. Keep the external comparator entirely outside royd's build, image and normal runtime dependencies.

Before measuring:

1. Pin both image digests and record Android build/security-patch identities, x86_64 ABIs, installed application versions and actual renderer/driver versions. An available registry manifest alone does not establish bootability or configuration parity. An Android 15 image is not necessarily the same AOSP revision. Review privileged host-global side effects before launching an external image; never share its Android data volume with royd or silently change host prerequisites.
2. Require passing baseline runtime, ordinary-UID native/WebView DNS/HTTPS and certificate-rejection evidence, plus a longer Settings/scroll/Home stream with full pre/post checks. Validate equivalent user-visible functionality independently on the comparator; royd-specific properties and service names are not comparator requirements. Retain unresolved diagnostics and explain their observed impact rather than requiring an empty log.
3. Match host, renderer, effective display size/density/frame rate, CPU allocation, memory/swap limits, fresh-data policy, scrcpy version/codec/bit rate and named workload. Verify the effective configuration, not just launch arguments. Different software renderers are not a renderer-controlled comparison; resolve that mismatch before publishing a controlled graphics ranking. Do not switch royd to an unqualified GPU backend to manufacture parity.
4. Use a common measurement procedure that does not depend on royd's product-specific assertions. Retain raw boot-to-Home, cold application launch, frame-timing, cgroup CPU and peak/settled memory observations and workload failures. A real-time recording's size, average frame rate and completion time do not measure unconstrained encoder throughput or interactive input latency. Mark unmeasured metrics explicitly.
5. Alternate the two images for at least five fresh-data repetitions each, running one measured instance at a time. Report medians and ranges, retain failed repetitions and distinguish fresh Android data from cold host page cache. Never clear host caches or change host networking, clocks or kernel settings as a hidden preparation step.

The first comparison should use the current low-memory baseline only. Performance-profile speed claims remain deferred; adding that profile later requires its own controlled comparison and memory accounting. Broader applications, long network/restart soaks, clean-build/reference-host review and other architectures remain separate work, not reasons to indefinitely delay an explicitly preliminary result.

The resource-profile runner above is not a cross-runtime harness: its boot-to-Home interval includes royd-specific runtime assertions before the Home launch, and its launch/provenance paths assume a royd image. Do not reuse those timings as neutral comparative boot measurements. A common measurement harness and independent comparator qualification are still required before the first paired result.


## Android image profile comparison

After building and importing both standard and minimal images, compare them under the same display profile and candidate memory limits:

```sh
ROYD_IMAGE_PROFILE_SWEEP_OUTPUT=image-profile-sweep.md \
make image-profile-sweep
```

The comparison records Docker image size and embeds the memory sweep for each Android image profile. Passing containers also report the profile property and installed package count. This makes build-time package removal measurable without changing the runtime display or memory-test methodology.
