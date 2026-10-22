#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
patch="$root/android/patches/android-15.0.0_r36/0065-netd-account-container-interface-ip-traffic.patch"
fixup="$root/android/patches/android-15.0.0_r36/0066-netd-separate-container-accounting-error-latch.patch"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
extract() {
    awk -v target="+++ b/$1" '
      /^diff --git / {copy=0}
      $0 == target {copy=1; next}
      copy && /^\+[^+]/ {print substr($0, 2)}
      copy && $0 == "+" {print ""}
    ' "$patch"
}
extract packages/modules/Connectivity/bpf/progs/royd_iface_account.h >"$tmp/royd_iface_account.h"
native=system/netd/server/RoydInterfaceAccounting.h
program=packages/modules/Connectivity/bpf/progs/netd.c
mkdir -p "$tmp/src/system/netd/server" "$tmp/src/packages/modules/Connectivity/bpf/progs"
extract "$native" >"$tmp/src/$native"
cp "$root/android/tests/fixtures/android15/metered-netd.c" "$tmp/src/$program"
apply_part() {
    awk -v target="diff --git a/$2 b/$2" '
      /^diff --git / {copy=($0 == target)}
      copy {print}
    ' "$1" | patch -s -p1 -d "$tmp/src"
}
apply_part "$patch" "$program"
apply_part "$fixup" "$program"
apply_part "$fixup" "$native"
cp "$tmp/src/$native" "$tmp/RoydInterfaceAccounting.h"
if [ -n "${ROYD_ANDROID15_ACCOUNTING_SOURCE:-}" ]; then
    cmp "$tmp/royd_iface_account.h" "$ROYD_ANDROID15_ACCOUNTING_SOURCE/packages/modules/Connectivity/bpf/progs/royd_iface_account.h"
    cmp "$tmp/RoydInterfaceAccounting.h" "$ROYD_ANDROID15_ACCOUNTING_SOURCE/system/netd/server/RoydInterfaceAccounting.h"
fi
${CC:-cc} -std=c11 -O2 -Wall -Wextra -Werror -I"$tmp" \
    "$root/android/tests/interface-accounting-packet.c" -o "$tmp/packet"
"$tmp/packet"
sed -n '/^static .*royd_owns_iface(/,/^DEFINE_OPTIONAL_BPF_PROG/p' "$tmp/src/$program" \
    | sed '/DEFINE_OPTIONAL_BPF_PROG/d' >"$tmp/royd_accounting_functions.h"
if [ -n "${ROYD_ANDROID15_ACCOUNTING_SOURCE:-}" ]; then
    sed -n '/^static .*royd_owns_iface(/,/^DEFINE_OPTIONAL_BPF_PROG/p' \
      "$ROYD_ANDROID15_ACCOUNTING_SOURCE/$program" | sed '/DEFINE_OPTIONAL_BPF_PROG/d' >"$tmp/applied-functions.h"
    cmp "$tmp/royd_accounting_functions.h" "$tmp/applied-functions.h"
fi
${CC:-cc} -std=c11 -O2 -Wall -Wextra -Werror -pthread -I"$tmp" \
    "$root/android/tests/interface-accounting-policy.c" -o "$tmp/policy"
"$tmp/policy"
${CXX:-c++} -std=c++17 -O2 -Wall -Wextra -Werror -I"$tmp" \
    -I"$root/android/tests/interface-accounting-stubs" \
    "$root/android/tests/interface-accounting-native.cpp" -o "$tmp/native"
"$tmp/native"
# Existing accounting sites bypass only the specifically owned interface.
[ "$(grep -c '^+    if (royd_owns_iface(skb->ifindex)) return' "$patch")" -eq 3 ]
! grep -Eq '^[-+].*(update_app_uid_stats_map\(skb|update_stats_with_config\(\*selectedMap)' "$patch"
grep -Fq '+        exit(1);' "$patch"
grep -Fq '+            if (royd::preserveQdisc(iface.c_str())) continue;' "$patch"
grep -Fq '+    if (royd::preserveQdisc(interface)) return;' "$patch"
test "$(grep -c '^+DEFINE_OPTIONAL_BPF_PROG' "$patch")" -eq 2
grep -Fq '+    const binder::Status dump_permission' "$patch" && exit 1
if [ -n "${ROYD_TEST_BPF_TREE:-}" ]; then
    (
      cd "$ROYD_TEST_BPF_TREE"
      prebuilts/clang/host/linux-x86/clang-r536225/bin/clang --target=bpf \
        -O2 -g -Wall -Werror -Wextra -nostdlibinc \
        -isystem bionic/libc/include -isystem bionic/libc/kernel/uapi \
        -isystem bionic/libc/kernel/uapi/asm-arm64 -isystem bionic/libc/kernel/android/uapi \
        -I packages/modules/Connectivity/bpf/headers/include \
        -I system/core/libcutils/include -I packages/modules/Connectivity/bpf/progs \
        -c "$program" -o "$tmp/netd.o"
    )
    printf '%s\n' 'Actual Android Clang BPF compilation passed'
fi
printf '%s\n' 'Android 15 private interface accounting contracts passed'
