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
- optional Docker memory and swap limits
- overridable display width, height, density, and frame rate

### `royd ps`

Lists containers labelled by the CLI as royd instances.

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
