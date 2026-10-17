#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir -p "$tmp/system/core/libprocessgroup/setup"
source="$tmp/system/core/libprocessgroup/setup/cgroup_map_write.cpp"
# Minimal upstream context. Apply the real ordered build inputs, not a copy of
# the implementation, then execute its gate and retry helper with fake I/O/time.
cat > "$source" <<'SRC'
#include <fcntl.h>
#include <grp.h>
#include <pwd.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#include <optional>

static bool IsOptionalController(const CgroupController* controller) {
    return controller->flags() & CGROUPRC_CONTROLLER_FLAG_OPTIONAL;
}

static bool MountV2CgroupController(const CgroupDescriptor& descriptor) {
    const CgroupController* controller = descriptor.controller();

    // /sys/fs/cgroup is created by cgroup2 with specific selinux permissions,
    // try to create again in case the mount point is changed
    if (!Mkdir(controller->path(), 0, "", "")) {
SRC
for patch in 0017-libprocessgroup-use-container-cgroup-subtree \
  0018-libprocessgroup-fix-cgroup-name-comparison \
  0020-libprocessgroup-delegate-memory-controller \
  0058-libprocessgroup-retry-busy-memory-delegation; do
  (cd "$tmp" && git apply "$root/android/patches/android-15.0.0_r36/$patch.patch")
done
if [ "$#" -gt 0 ]; then source=$1; fi
cat > "$tmp/test.cpp" <<'CPP'
#include <cassert>
#include <cerrno>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <sstream>
#include <string>
#include <vector>
static int writes, sleeps, error_code, busy_count, selinux_error, controllers_error;
static int init_moves;
static bool prepare_ok = true, move_ok = true;
static long elapsed;
static std::ostringstream logs;
#define LOG(level) logs
#define PLOG(level) logs
struct FakeClock {
    static std::chrono::milliseconds now() { return std::chrono::milliseconds(elapsed); }
};
static void fake_sleep(std::chrono::milliseconds duration) {
    assert(duration.count() == 50);
    ++sleeps;
    elapsed += duration.count();
}
namespace android::base {
static bool WriteStringToFile(const char* value, const char* path) {
    assert(std::string(value) == "+memory");
    assert(std::string(path) == "/sys/fs/cgroup/cgroup.subtree_control");
    ++writes;
    if (busy_count < 0 || writes <= busy_count) { errno = EBUSY; return false; }
    errno = error_code;
    return error_code == 0;
}
static bool WriteStringToFile(const std::string& value, const std::string& path) {
    assert(value == "1" && path == "/sys/fs/cgroup/royd/init/cgroup.procs");
    ++init_moves;
    return move_ok;
}
}
static int fake_access(const char* path, int) {
    errno = std::string(path) == "/sys/fs/selinux/enforce" ? selinux_error : controllers_error;
    return errno ? -1 : 0;
}
constexpr int F_OK = 0;
const std::string CGROUPV2_HIERARCHY_NAME = "cgroup2";
struct CgroupController {
    std::string controller_name = "cgroup2", controller_path = "/sys/fs/cgroup/royd";
    const std::string& name() const { return controller_name; }
    const char* path() const { return controller_path.c_str(); }
};
struct CgroupDescriptor {
    CgroupController value;
    const CgroupController* controller() const { return &value; }
    int mode() const { return 0775; }
    std::string uid() const { return "system"; }
    std::string gid() const { return "system"; }
};
static bool Mkdir(const std::string& path, int, const std::string&, const std::string&) {
    assert(path == "/sys/fs/cgroup/royd" || path == "/sys/fs/cgroup/royd/init");
    return prepare_ok;
}
static bool ChangePathModeAndOwner(const std::string& path, int mode,
                                  const std::string& uid, const std::string& gid) {
    assert(path == "/sys/fs/cgroup/royd" && mode == 0775 && uid == "system" && gid == "system");
    return prepare_ok;
}
static int fake_getpid() { return 1; }
CPP
{
  sed -n '/^static bool IsRoydContainerCgroup(/,/^}/p; /^static bool DelegateRoydMemoryController(/,/^}/p' "$source"
  # Execute the actual gated caller. Its stock fallback is not part of this
  # host harness and remains checked by the existing cgroup/sync contracts.
  awk '/^static bool MountV2CgroupController/ {emit=1} emit && /\/\/ \/sys\/fs\/cgroup is created/ {exit} emit {print}' "$source"
  printf 'return false;\n}\n'
} | sed 's/std::chrono::steady_clock/FakeClock/g; s/std::this_thread::sleep_for/fake_sleep/g; s/access(/fake_access(/g; s/getpid()/fake_getpid()/g' >> "$tmp/test.cpp"
cat >> "$tmp/test.cpp" <<'CPP'
static void reset(int busy = 0, int error = 0) {
    writes = sleeps = init_moves = elapsed = 0;
    busy_count = busy;
    error_code = error;
    logs.str(""); logs.clear();
}
static size_t count(const std::string& marker) {
    size_t result = 0, pos = 0;
    while ((pos = logs.str().find(marker, pos)) != std::string::npos) { ++result; pos += marker.size(); }
    return result;
}
int main() {
    reset(); assert(DelegateRoydMemoryController());
    assert(writes == 1 && sleeps == 0 && logs.str().empty());
    reset(3); assert(DelegateRoydMemoryController());
    assert(writes == 4 && sleeps == 3 && elapsed == 150);
    assert(count("waiting for busy") == 1 && count("after retry") == 1);
    reset(-1); assert(!DelegateRoydMemoryController());
    assert(errno == EBUSY && writes == 201 && sleeps == 200 && elapsed == 10000);
    assert(count("waiting for busy") == 1 && count("after retry") == 0);
    assert(count("Failed to delegate") == 1);
    for (int error : {ENOENT, EACCES, EPERM, EIO, EINTR, EINVAL, EROFS}) {
        reset(0, error); assert(!DelegateRoydMemoryController());
        assert(errno == error && writes == 1 && sleeps == 0);
        reset(2, error); assert(!DelegateRoydMemoryController());
        assert(errno == error && writes == 3 && sleeps == 2);
        assert(count("Failed to delegate") == 1 && count("after retry") == 0);
    }
    CgroupController controller;
    selinux_error = ENOENT; controllers_error = 0;
    unsetenv("ROYD_CONTAINER"); assert(!IsRoydContainerCgroup(&controller));
    for (const char* value : {"", "0", "true", "11"}) {
        setenv("ROYD_CONTAINER", value, 1); assert(!IsRoydContainerCgroup(&controller));
    }
    setenv("ROYD_CONTAINER", "1", 1); assert(IsRoydContainerCgroup(&controller));
    for (int error : {0, EACCES, EIO, EPERM}) {
        selinux_error = error; assert(!IsRoydContainerCgroup(&controller));
    }
    selinux_error = ENOENT;
    controllers_error = ENOENT; assert(!IsRoydContainerCgroup(&controller));
    controllers_error = 0;
    controller.controller_name = "memory"; assert(!IsRoydContainerCgroup(&controller));
    controller.controller_name = "cgroup2";
    controller.controller_path = "/sys/fs/cgroup"; assert(!IsRoydContainerCgroup(&controller));
    CgroupDescriptor descriptor;
    reset(3); assert(MountV2CgroupController(descriptor));
    assert(init_moves == 1 && count("using delegated cgroup v2 subtree") == 1);
    reset(-1); assert(!MountV2CgroupController(descriptor));
    assert(init_moves == 1 && count("using delegated cgroup v2 subtree") == 0);
    reset(0, EACCES); assert(!MountV2CgroupController(descriptor));
    assert(writes == 1 && count("using delegated cgroup v2 subtree") == 0);
    reset(); prepare_ok = false; assert(!MountV2CgroupController(descriptor));
    assert(writes == 0 && init_moves == 0);
    reset(); prepare_ok = true; move_ok = false; assert(!MountV2CgroupController(descriptor));
    assert(writes == 0 && init_moves == 1);
    move_ok = true;
    for (int error : {0, EACCES, EIO}) {
        reset(); selinux_error = error; assert(!MountV2CgroupController(descriptor));
        assert(writes == 0 && sleeps == 0 && init_moves == 0);
    }
}
CPP
"${CXX:-c++}" -std=c++17 -Wall -Wextra -Werror "$tmp/test.cpp" -o "$tmp/test"
"$tmp/test"
# Failure must return before the existing success marker, within the gate.
grep -A2 -F 'if (!DelegateRoydMemoryController()) {' "$source" | grep -Fq 'return false;'
test "$(grep -c 'if (!DelegateRoydMemoryController())' "$source")" -eq 1
printf '%s\n' 'Android 15 memory-delegation retry contract passed'
