#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
bash -n "$root/runtime/scripts/network-accounting-test.sh"
sh -n "$root/runtime/scripts/network-accounting-build.sh"
PYTHONDONTWRITEBYTECODE=1 python3 "$root/runtime/tests/network-accounting/assess_test.py"
go test "$root/runtime/tests/network-accounting/traffic.go" "$root/runtime/tests/network-accounting/traffic_test.go"
# Compilation is optional in portable CI. The real runner requires these APIs
# and proves actual load/attachment capability in its owned network namespace.
if command -v cc >/dev/null 2>&1 && printf '#include <linux/bpf.h>\nint main(void) { return BPF_TCX_INGRESS; }\n' | cc -x c -fsyntax-only - >/dev/null 2>&1; then
  cc -Wall -Wextra -Werror -fsyntax-only "$root/runtime/tests/network-accounting/observe.c"
else
  printf '%s\n' 'TCX observer C compilation not checked: modern Linux UAPI/compiler unavailable'
fi
compiler=${ROYD_ACCOUNTING_CLANG:-$root/.work/android-src-15/prebuilts/clang/host/linux-x86/clang-r536225/bin/clang}
if [ -x "$compiler" ] && [ -f /usr/include/x86_64-linux-gnu/asm/types.h ]; then
  "$compiler" -O2 -target bpfel -I/usr/include/x86_64-linux-gnu -fsyntax-only "$root/runtime/tests/network-accounting/observe.bpf.c"
else
  printf '%s\n' 'Observer BPF compilation not checked: configured Android Clang/UAPI unavailable'
fi
printf '%s\n' 'Native UDP accounting, receipt, segmentation and observer contracts passed'
