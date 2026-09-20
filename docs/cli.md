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
- whether Docker is available
- whether `/proc/filesystems` advertises `binder`
- whether `/dev/dri` exists for possible host GPU access

### `royd run`

Runs a local royd container with conventional defaults:

- image: `royd:dev`
- name: `royd`
- privileged container
- `/data` volume mounted from `royd-data`
- ADB port published on `127.0.0.1:5555`

### `royd ps`

Lists containers labelled by the CLI as royd instances.

### `royd logs`

Follows Docker logs for a given container. This is intended to surface the forwarded Android `logcat` stream.

### `royd version`

Prints the CLI version.

## Non-goals for now

The current CLI does not yet:

- generate Compose files
- wrap ADB
- manage multi-instance topologies
- install kernel modules
- mutate host networking or filesystems
- replace Docker or Compose usage in documentation
