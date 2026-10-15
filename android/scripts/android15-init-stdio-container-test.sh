#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
patch="$root/android/patches/android-15.0.0_r36/0016-init-preserve-container-output.patch"

[ -f "$patch" ] || { echo 'missing Android 15 init OCI output patch' >&2; exit 1; }
[ "$(grep -c '^diff --git a/system/core/init/util.cpp' "$patch")" -eq 1 ]
[ "$(grep -c '^diff --git ' "$patch")" -eq 1 ]
grep -F '+#include <selinux/selinux.h>' "$patch" >/dev/null
grep -F 'const char* royd_container = getenv("ROYD_CONTAINER");' "$patch" >/dev/null
grep -F 'strcmp(royd_container, "1") == 0 && is_selinux_enabled() <= 0;' "$patch" >/dev/null
grep -F 'const bool preserve_container_output = royd_container != nullptr &&' "$patch" >/dev/null
grep -F 'if (!preserve_container_output) {' "$patch" >/dev/null

# Stdin remains /dev/null and the stock output redirects remain present behind
# the narrow container gate. Descriptor closure and fatal open handling stay unchanged.
if grep -Eq '^[+-].*dup2\(fd, STDIN_FILENO\)' "$patch"; then
  echo 'init OCI output patch changes the stock stdin redirect' >&2
  exit 1
fi
grep -F 'dup2(fd, STDOUT_FILENO);' "$patch" >/dev/null
grep -F 'dup2(fd, STDERR_FILENO);' "$patch" >/dev/null
if grep -Eq '^[+-].*(PLOG\(FATAL\).*Couldn.t open /dev/null|if \(fd > STDERR_FILENO\) close\(fd\))' "$patch"; then
  echo 'init OCI output patch changes stock fatal or descriptor-close handling' >&2
  exit 1
fi

if grep -Fq 'ROYD_DIAG' "$patch"; then
  echo 'permanent init OCI output patch retains a diagnostic-only marker' >&2
  exit 1
fi

logging_patch="$root/android/patches/android-15.0.0_r36/0046-init-route-container-diagnostics-to-stderr.patch"
[ "$(grep -c '^diff --git ' "$logging_patch")" -eq 1 ]
grep -Fq 'diff --git a/system/core/init/util.cpp' "$logging_patch"
! grep -Eq '^-[^-]' "$logging_patch"
# Execute the exact logger-selection function, preserving argv, fatal setup and aborter.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
cat >"$tmp/logging.cpp" <<'CPP'
#include <cassert>
#include <cstdio>
#include <cstring>
static const char* marker;
static int selinux;
static int fatal_setup;
static int initialisations;
static int kernel_messages;
static int stderr_messages;
static char** expected_argv;
using Logger = void (*)(const char*);
static Logger selected;
static void InitAborter() {}
static void SetFatalRebootTarget() { fatal_setup++; }
static int is_selinux_enabled() { return selinux; }
static const char* test_getenv(const char* name) {
    assert(strcmp(name, "ROYD_CONTAINER") == 0);
    return marker;
}
#define getenv test_getenv
namespace android::base {
static void KernelLogger(const char*) { kernel_messages++; }
static void StderrLogger(const char* message) {
    stderr_messages++;
    fprintf(stderr, "%s\n", message);
}
static void InitLogging(char** argv, Logger logger, void (*aborter)()) {
    assert(argv == expected_argv);
    assert(aborter == InitAborter);
    assert(fatal_setup == initialisations + 1);
    initialisations++;
    selected = logger;
}
}
struct Sink {
    void operator<<(const char* message) { selected(message); }
};
#define LOG(level) Sink{}
CPP
awk '
  /^ void InitKernelLogging/ { copy = 1 }
  copy && /^[ +]/ { print substr($0, 2) }
  copy && /^ }/ { exit }
' "$logging_patch" >>"$tmp/logging.cpp"
cat >>"$tmp/logging.cpp" <<'CPP'
int main() {
    static char name[] = "init";
    static char* argv[] = {name, nullptr};
    expected_argv = argv;
    const char* markers[] = {nullptr, "", "0", "true", "1"};
    const int states[] = {-1, 0, 1, 2};
    for (const char* value : markers) {
        marker = value;
        for (int state : states) {
            selinux = state;
            const bool gated = value && strcmp(value, "1") == 0 && state <= 0;
            const int before = stderr_messages;
            InitKernelLogging(argv);
            assert(selected == (gated ? android::base::StderrLogger : android::base::KernelLogger));
            assert(stderr_messages == before + int(gated));
            // Every ordinary init diagnostic follows the same selected sink.
            selected("ordinary init diagnostic");
            assert(stderr_messages == before + 2 * int(gated));
        }
    }
    assert(fatal_setup == 20 && initialisations == 20);
    assert(kernel_messages == 18 && stderr_messages == 4);
}
CPP
c++ -std=c++17 -Wall -Wextra -Werror "$tmp/logging.cpp" -o "$tmp/logging"
"$tmp/logging" >"$tmp/stdout" 2>"$tmp/stderr"
[ ! -s "$tmp/stdout" ]
[ "$(grep -Fc 'ROYD: routing init diagnostics to container stderr' "$tmp/stderr")" -eq 2 ]
[ "$(grep -Fc 'ordinary init diagnostic' "$tmp/stderr")" -eq 2 ]
printf '%s\n' 'Android 15 init OCI output and diagnostic routing contracts passed'
