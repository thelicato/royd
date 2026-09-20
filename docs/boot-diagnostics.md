# Boot diagnostics

royd starts a bounded boot watchdog when Android's zygote enters the running state. The watchdog waits for `sys.boot_completed=1`. If Android does not complete boot within 120 seconds, it writes a diagnostic snapshot directly to PID 1 stdout, so the evidence is visible through `docker logs` even when ADB never becomes usable.

The snapshot includes royd and init service properties, Binder devices, relevant mounts, PID 1 status, memory and PSI state, the process list, Binder service registrations, and the most recent Android logcat lines. The watchdog is diagnostic only: it does not reboot, kill, or otherwise recover the container.

The same snapshot can be requested manually inside a container with `/vendor/bin/royd-diagnostics`.

The default timeout is controlled by the read-only product property `ro.vendor.royd.boot_watchdog_timeout` and defaults to 120 seconds. Real-host qualification must still confirm that the captured output is sufficient for representative failed boots before the roadmap validation item is considered complete.
