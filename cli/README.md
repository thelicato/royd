# CLI

The optional `royd` CLI is written in Go.

It is a convenience layer only. The Docker and Compose workflows remain the primary interfaces and must continue to work without the CLI.

The current scaffold provides:

- `royd doctor` for Linux, Docker, Binder, cgroup, PSI, and optional GPU checks.
- `royd run` for a conventional `docker run` invocation with optional memory and display tuning.
- `royd ps` for listing containers created through the CLI.
- `royd logs` for following container logs.
- `royd status` for container state, Docker health, and the published ADB endpoint.
- `royd adb` for forwarding commands to an ADB-over-TCP endpoint.
- `royd shell` for opening `/system/bin/sh` inside a running instance.
- `royd stop` for stopping an instance.
- `royd rm` for removing an instance.
- `royd version` for version output.

The current implementation focuses on predictable local Docker workflows. Docker commands are printed before execution so the CLI remains transparent. It does not yet generate Compose files, manage container updates, or provide advanced remote orchestration. ADB support is intentionally a thin wrapper around the host `adb` command.

Build and test it with:

```sh
make cli-test
make cli-build
```
