# ADB and container health

royd exposes Android Debug Bridge over TCP on port 5555 by default. The container image configures `adbd` for TCP during Android boot and exposes the port through OCI metadata. Docker or Compose still decides whether the port is published to the host.

Development containers default to `royd.adb_auth=disabled` for local workflows. Android 15 also supports `royd.adb_auth=required`, using stock Android key authentication. Keep the loopback publication and use an SSH tunnel for remote scrcpy: ADB key authentication does not encrypt this TCP connection or reduce the container's privileges.

## Docker

Publish ADB only on loopback unless remote access is intentional:

```sh
docker run -d \
  --name royd \
  --privileged \
  -p 127.0.0.1:5555:5555 \
  -v royd-data:/data \
  royd:dev
```

Then connect normally:

```sh
adb connect 127.0.0.1:5555
adb -s 127.0.0.1:5555 shell
adb -s 127.0.0.1:5555 logcat
```

The repository validation helper checks connectivity, Android boot completion, `adbd`, and a small `logcat` query:

```sh
make runtime-adb-contract-test
make runtime-adb-check
```

Override the endpoint with `ROYD_ADB_HOST`, `ROYD_ADB_PORT`, or `ROYD_ADB_SERIAL`.

## Authenticated Android 15

Copy the connecting workstation's **public** ADB key to the container host, mount it at stock `/adb_keys` and select required authentication. Never copy or mount its private key. Create a key with `adb keygen /private/client/adbkey` if that client does not have one; start the client's ADB server with `ADB_VENDOR_KEYS=/private/client/adbkey` to use it.

```sh
docker run -d \
  --name royd \
  --privileged \
  -p 127.0.0.1:5555:5555 \
  -v royd-data:/data \
  --mount type=bind,src=/absolute/path/to/client/adbkey.pub,dst=/adb_keys,readonly \
  royd:dev royd.adb_auth=required
```

`--mount` refuses a missing source instead of creating a directory. Use a readable public-key file. Verify the selected mode with `docker exec royd getprop ro.adb.secure`, which must return `1`; a client without an authorised key must remain `unauthorized` and cannot run a shell. An authorised client can use the normal `adb connect`, `adb shell` and scrcpy commands. Stock interactive authorisation and previously authorised keys in persistent `/data/misc/adb/adb_keys` still apply. Removing a key from `/adb_keys` does not revoke a copy authorised in `/data` or an existing connection.

For Compose, set `ROYD_ADB_AUTH=required` and add a read-only `/adb_keys` bind through a local Compose override. The base file has no mandatory host key path. Required mode is rejected on other Android versions or missing version metadata. Android 15's built-in `ro.adb.secure=1` remains in effect if the gated container property loader is unavailable; the normal disabled mode is explicitly selected through that loader before Android init publishes boot properties. Recreate the container to change modes. Missing or unusable keys never select disabled mode automatically.

On a remote workstation, forward the loopback port over SSH, then connect scrcpy through ADB as usual:

```sh
ssh -N -L 5555:127.0.0.1:5555 user@container-host
# In another terminal on the workstation:
adb connect 127.0.0.1:5555
scrcpy -s 127.0.0.1:5555
```

## CLI

The optional CLI provides a thin ADB wrapper:

```sh
royd adb
royd adb shell getprop sys.boot_completed
royd adb logcat
royd adb --serial 127.0.0.1:5560 shell
```

It runs `adb connect` first, then forwards the remaining arguments to the selected TCP serial.

## Health check

Every imported royd image carries an OCI health check that runs `/vendor/bin/royd-health`. A container becomes healthy when:

- Android reports `sys.boot_completed=1`
- `adbd` is running
- the ADB TCP port property is `5555`
- Binder, HwBinder, and vendor Binder device nodes are available

Inspect health with standard Docker tooling:

```sh
docker ps
make runtime-status
royd status royd
```

The health check is intentionally internal to the container. It does not require the host to have `adb` installed.
