# CLI

The optional `royd` CLI is written in Go.

It is a convenience layer only. The Docker and Compose workflows remain the primary interfaces and must continue to work without the CLI.

The current scaffold provides:

- `royd doctor` for lightweight host checks.
- `royd run` for a conventional `docker run` invocation.
- `royd ps` for listing containers created through the CLI.
- `royd logs` for following container logs.
- `royd version` for version output.

The current implementation focuses on predictable local Docker workflows. It does not yet manage ADB, Compose generation, container updates, or advanced host diagnostics.

Build and test it with:

```sh
make cli-test
make cli-build
```
