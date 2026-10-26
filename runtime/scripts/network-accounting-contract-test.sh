#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
bash -n "$root/runtime/scripts/network-accounting-test.sh" "$root/runtime/scripts/network-accounting-policy.sh"
sh -n "$root/runtime/scripts/network-accounting-build.sh"
"$root/runtime/scripts/network-accounting-policy-contract-test.sh"
PYTHONDONTWRITEBYTECODE=1 python3 "$root/runtime/tests/network-accounting/assess_test.py"
PYTHONDONTWRITEBYTECODE=1 python3 "$root/runtime/tests/network-accounting/assess_tcp_test.py"
PYTHONDONTWRITEBYTECODE=1 python3 "$root/runtime/tests/network-accounting/assess_policy_test.py"
go test "$root/runtime/tests/network-accounting/traffic.go" "$root/runtime/tests/network-accounting/tcp.go" "$root/runtime/tests/network-accounting/policy.go" "$root/runtime/tests/network-accounting/udp_diag.go" "$root/runtime/tests/network-accounting/traffic_test.go" "$root/runtime/tests/network-accounting/tcp_test.go" "$root/runtime/tests/network-accounting/policy_test.go" "$root/runtime/tests/network-accounting/udp_diag_test.go"
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
tree=${ROYD_ANDROID_TEST_TREE:-$root/.work/android-src-15}
modules=${ROYD_ANDROID_TEST_SYSTEM_MODULES:-$tree/out/soong/.intermediates/libcore/core-all-system-modules/android_common/system}
jdk=$tree/prebuilts/jdk/jdk21/linux-x86
if [ -x "$jdk/bin/javac" ] && [ -f "$modules/lib/modules" ] && [ -f "$tree/prebuilts/sdk/current/public/android.jar" ]; then
  api_tmp=$(mktemp -d)
  trap 'rm -rf "$api_tmp"' EXIT
  "$jdk/bin/javac" --system "$modules" -source 17 -target 17 -classpath "$tree/prebuilts/sdk/current/public/android.jar" -d "$api_tmp" "$root"/runtime/tests/network-dns/AccountingProbe*.java
  cat >"$api_tmp/Unsupported.java" <<'JAVA'
import java.nio.file.Files;
import java.nio.file.Path;
class Unsupported { String read(Path p) throws Exception { return Files.readString(p); } }
JAVA
  if "$jdk/bin/javac" --system "$modules" -source 17 -target 17 -classpath "$tree/prebuilts/sdk/current/public/android.jar" -d "$api_tmp" "$api_tmp/Unsupported.java" >"$api_tmp/unsupported.log" 2>&1; then
    printf '%s\n' 'error: unavailable Android 15 Java API was accepted' >&2
    exit 1
  fi
  grep -Fq 'method readString(Path)' "$api_tmp/unsupported.log"
  printf '%s\n' 'Actual Android core API accepts the probes and rejects unavailable Files.readString'
else
  printf '%s\n' 'Android core API compilation not checked: applied Android 15 system modules unavailable'
fi
printf '%s\n' 'Native UDP/TCP and ordinary-UID policy accounting contracts passed'
