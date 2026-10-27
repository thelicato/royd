#!/bin/sh
set -eu
ulimit -c 0
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
patch=$root/android/patches/android-15.0.0_r36/0071-netd-enforce-container-interface-byte-quotas.patch
extract() {
 awk -v target="+++ b/$1" '
  /^diff --git / {copy=0}
  $0 == target {copy=1; next}
  copy && /^\+[^+]/ {print substr($0,2)}
  copy && $0 == "+" {print ""}
 ' "$patch"
}
for name in royd_quota.h roydquota.c; do
 extract "packages/modules/Connectivity/bpf/progs/$name" >"$tmp/$name"
 test -s "$tmp/$name"
done
extract system/netd/server/RoydInterfaceQuota.h >"$tmp/RoydInterfaceQuota.h"
awk '
 /^diff --git / {copy=0}
 $0 == "+++ b/packages/modules/Connectivity/bpf/progs/royd_iface_account.h" {copy=1;next}
 copy && /^\+[^+]/ {print substr($0,2)}
 copy && $0 == "+" {print ""}
' "$root/android/patches/android-15.0.0_r36/0065-netd-account-container-interface-ip-traffic.patch" >"$tmp/royd_iface_account.h"
sed -n '/^static .*royd_quota_packet(/,/^DEFINE_OPTIONAL_BPF_PROG/p' "$tmp/roydquota.c" \
 | sed '/DEFINE_OPTIONAL_BPF_PROG/d' >"$tmp/quota-packet-function.h"
${CC:-cc} -std=c11 -O2 -Wall -Wextra -Werror -pthread -I"$tmp" \
 "$root/android/tests/interface-quota-core.c" -o "$tmp/core"
"$tmp/core"
${CC:-cc} -std=c11 -O2 -Wall -Wextra -Werror -I"$tmp" \
 "$root/android/tests/interface-quota-packet.c" -o "$tmp/packet"
"$tmp/packet"
: >"$tmp/RoydInterfaceAccounting.h"
${CXX:-c++} -std=c++17 -O2 -Wall -Wextra -Werror -pthread -I"$tmp" \
 "$root/android/tests/interface-quota-native.cpp" -o "$tmp/native"
"$tmp/native"
python3 "$root/android/tests/interface-quota-controller.py" "$root" "$tmp"
python3 "$root/runtime/scripts/assert-interface-quota-test.py"
if [ -n "${ROYD_ANDROID15_QUOTA_SOURCE:-}" ]; then
 for name in royd_quota.h roydquota.c; do
  cmp "$tmp/$name" "$ROYD_ANDROID15_QUOTA_SOURCE/packages/modules/Connectivity/bpf/progs/$name"
 done
 cmp "$tmp/RoydInterfaceQuota.h" "$ROYD_ANDROID15_QUOTA_SOURCE/system/netd/server/RoydInterfaceQuota.h"
fi
if [ -n "${ROYD_TEST_BPF_TREE:-}" ]; then
 tree=$ROYD_TEST_BPF_TREE
 compiler=$tree/prebuilts/clang/host/linux-x86/clang-r536225/bin/clang
 "$compiler" --target=bpf -mcpu=v3 -O2 -g -Wall -Werror -Wextra -nostdlibinc \
  -isystem "$tree/bionic/libc/include" -isystem "$tree/bionic/libc/kernel/uapi" \
  -isystem "$tree/bionic/libc/kernel/uapi/asm-arm64" -isystem "$tree/bionic/libc/kernel/android/uapi" \
  -I "$tree/packages/modules/Connectivity/bpf/headers/include" \
  -I "$tree/system/core/libcutils/include" -I "$tree/packages/modules/Connectivity/bpf/progs" \
  -c "$tmp/roydquota.c" -o "$tmp/roydquota.o"
 printf '%s\n' 'Actual Android Clang quota BPF compilation passed'
 if [ "${ROYD_QUOTA_KERNEL_TEST:-0}" = 1 ]; then
  output=${ROYD_QUOTA_KERNEL_OUTPUT_DIR:?new kernel evidence directory required}
  PYTHONDONTWRITEBYTECODE=1 timeout 60 python3 "$root/android/tests/interface-quota-kernel.py" "$tmp/roydquota.o" "$output"
  cp "$tmp/roydquota.o" "$output/roydquota.o"
 fi
elif [ "${ROYD_QUOTA_KERNEL_TEST:-0}" = 1 ]; then
 printf '%s\n' 'error: ROYD_TEST_BPF_TREE required for actual kernel gate' >&2
 exit 1
fi
printf '%s\n' 'Android 15 shared interface byte-quota contracts passed'
