# CLI

royd keeps the OCI image as the primary product and treats the CLI as optional convenience tooling.

## Goals

- Keep all core runtime capabilities available through plain Docker or Compose.
- Provide a small, scriptable interface for common local workflows.
- Prefer explicit Docker invocations over hidden long-running helpers.
- Fail clearly when Docker or required host features are unavailable.

## Current commands

### `royd doctor`

Reports lightweight host checks relevant to the current runtime path:

- operating system and architecture
- whether the host is Linux
- whether Docker is installed and the daemon is reachable
- whether `/proc/filesystems` advertises `binder`
- whether cgroup v2 and memory PSI are available
- whether `/dev/dri` exists for possible host GPU access

### `royd run`

Runs a local royd container with conventional defaults:

- image: `royd:dev`
- name: `royd`
- privileged container
- `/data` volume mounted from `royd-data`
- ADB port published on `127.0.0.1:5555`
- privileged security mode by default, with `--security experimental` available for capability-reduction tests
- optional Docker memory and swap limits
- overridable display width, height, density, and frame rate

`royd run` also accepts `--graphics software`, `--graphics host-gpu-generic`, or `--graphics host-gpu-intel`. Host GPU modes select the matching development image alias and pass `/dev/dri` into the container.

### `royd ps`

Lists containers labelled by the CLI as royd instances.


### `royd status`

Reports Docker state, Docker health, and the published ADB endpoint for a container.

### `royd adb`

Connects to an ADB-over-TCP serial and forwards the remaining arguments to the host `adb` command. The default serial is `127.0.0.1:5555`.

### `royd logs`

Follows Docker logs for a given container. This is intended to surface the forwarded Android `logcat` stream.

### `royd shell`

Opens `/system/bin/sh` in a running royd container through `docker exec -it`.

### `royd stop`

Stops a named royd container.

### `royd rm`

Removes a named royd container. `-f` may be used when force removal is explicitly wanted. Persistent Docker volumes are not removed automatically.

### `royd version`

Prints the CLI version.

## Transparency

Docker operations are echoed before they execute. This keeps the CLI behaviour visible and makes it straightforward to reproduce the same action without the CLI.

## Non-goals for now

The current CLI does not yet:

- generate Compose files
- wrap ADB
- manage multi-instance topologies
- install kernel modules
- mutate host networking or filesystems
- replace Docker or Compose usage in documentation

## ADB and status

`royd status [container]` reports Docker state, Docker health, and the published ADB endpoint. `royd adb` connects to `127.0.0.1:5555` by default and forwards subsequent arguments to the host `adb` command. Use `--serial` when the container is published on another port.
