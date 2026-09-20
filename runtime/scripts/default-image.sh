#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
profile=${1:-standard}
arch=${2:-x86_64}
exec "$script_dir/image-alias.sh" "$arch" "$profile"
