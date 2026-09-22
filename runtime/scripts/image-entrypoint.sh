#!/bin/sh
set -eu

rootfs_source=${1:-}
case "$rootfs_source" in
  ramdisk)
    printf '%s\n' '["/royd-entrypoint"]'
    ;;
  system)
    printf '%s\n' '["/system/bin/bootstrap/linker64","/system/bin/sh","/royd-entrypoint"]'
    ;;
  *)
    printf 'error: unsupported Android rootfs source for OCI entrypoint: %s\n' "${rootfs_source:-unset}" >&2
    exit 1
    ;;
esac
