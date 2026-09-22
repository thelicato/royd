#!/bin/sh
set -eu

printf '%s\n' '--tmpfs=/dev/socket:rw,nosuid,nodev,noexec,mode=0755'
