#!/bin/sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
out=${1:?new build directory required}
compiler=${ROYD_ACCOUNTING_CLANG:-$root/.work/android-src-15/prebuilts/clang/host/linux-x86/clang-r536225/bin/clang}
[ "$(uname -m)" = x86_64 ]
mkdir "$out"
"$compiler" -O2 -g -target bpfel -I/usr/include/x86_64-linux-gnu -c "$root/runtime/tests/network-accounting/observe.bpf.c" -o "$out/observe.bpf.o"
cc -O2 -Wall -Wextra -Werror "$root/runtime/tests/network-accounting/observe.c" -Wl,-l:libbpf.so.1 -o "$out/observe"
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o "$out/traffic" "$root/runtime/tests/network-accounting/traffic.go" "$root/runtime/tests/network-accounting/tcp.go"
