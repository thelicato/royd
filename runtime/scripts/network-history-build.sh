#!/bin/sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
output=${1:?new build directory required}
"$script_dir/network-dns-build.sh" "$output"
go build -o "$output/../history-assess" "$root/runtime/tests/network-history/assess.go"
