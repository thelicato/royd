# Boot diagnostics

royd starts a bounded boot watchdog when Android's zygote enters the running state. The watchdog waits for `sys.boot_completed=1`. If Android does not complete boot within 120 seconds, it writes a diagnostic snapshot directly to PID 1 stdout, so the evidence is visible through `docker logs` even when ADB never becomes usable.

The snapshot includes royd and init service properties, Binder devices, relevant mounts, PID 1 status, memory and PSI state, the process list, Binder service registrations, and the most recent Android logcat lines. The watchdog is diagnostic only: it does not reboot, kill, or otherwise recover the container.

The same snapshot can be requested manually inside a container with `/vendor/bin/royd-diagnostics`. Runtime qualification also persists the complete timestamped Docker log stream, Docker inspect output, and a concise container state snapshot before removing its disposable container. Reference-host bundles include those files so failed-boot evidence remains reviewable after collection.

The default timeout is controlled by the read-only product property `ro.vendor.royd.boot_watchdog_timeout` and defaults to 120 seconds. Real-host qualification must still confirm that the captured output is sufficient for representative failed boots before the roadmap validation item is considered complete.

## Android 15 derived classpath

Android 15 does not bake `BOOTCLASSPATH`, `DEX2OATBOOTCLASSPATH`, or `SYSTEMSERVERCLASSPATH` into `root/init.environ.rc`. After APEX activation, stock init runs `derive_classpath` and loads `/data/system/environ/classpath`. The product already reaches AOSP's default ART configuration through the system-product inheritance chain (`generic_system.mk` -> `handheld_system.mk` -> `media_system.mk` -> `base_system.mk` -> `runtime_libart.mk`), so adding another direct `default_art_config.mk` inheritance is not a fix for an empty zygote environment.

For the Android 15 boot frontier, keep diagnostics narrow. Before packaging, verify only `system/etc/classpaths/bootclasspath.pb`, `system/etc/classpaths/systemserverclasspath.pb`, and the `com.android.sdkext` APEX. During a failed boot, inspect `/data/system/environ/classpath`, `init.svc.derive_classpath`, and log lines tagged `derive_classpath` before changing ART product composition.
