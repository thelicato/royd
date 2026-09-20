# ADB and container health

royd exposes Android Debug Bridge over TCP on port 5555 by default. The container image configures `adbd` for TCP during Android boot and exposes the port through OCI metadata. Docker or Compose still decides whether the port is published to the host.

Development images disable ADB authentication with `ro.adb.secure=0`. This is intentional for local container workflows and is not a production security boundary. Do not publish port 5555 on an untrusted interface.

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
