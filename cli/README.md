# Optional CLI

This directory is reserved for the optional `royd` command-line client written in Go.

The CLI is not required to run an Android container. It may provide host diagnostics and convenience wrappers around normal OCI and ADB workflows, but the underlying commands and configuration must remain available without it.

CLI implementation should begin only after the runtime has a stable enough host contract for `royd doctor` to validate something concrete.
