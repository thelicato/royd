"""Exercise the init peer-context correction and unchanged property checks with mocks."""
from pathlib import Path
import os
import resource
import subprocess
import sys

root, temporary = map(Path, sys.argv[1:])
resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
relative = Path('system/core/init/property_service.cpp')
source = temporary / relative
source.parent.mkdir(parents=True)
# The fixture contains selected functions from the pinned source and preceding patches.
stock = (root / 'android/tests/fixtures/android15/PropertyService.cpp').read_text()
source.write_text(stock)
subprocess.run(['patch', '--fuzz=0', '-s', '-p1', '-d', str(temporary)],
               input=(root / 'android/patches/android-15.0.0_r36/0093-init-handle-unavailable-property-peer-context.patch').read_text(),
               text=True, check=True)
patched = source.read_text()


def block(text, signature):
    start = text.index(signature)
    opening = text.index('{', start)
    depth = 1
    for end in range(opening + 1, len(text)):
        depth += (text[end] == '{') - (text[end] == '}')
        if not depth:
            return text[start:end + 1]
    raise AssertionError(signature)


signature = 'bool GetSourceContext(std::string* source_context) const'
# No socket, credential, permission, writer, control or persistence code may change.
assert patched.replace(block(patched, signature), block(stock, signature)) == stock
unchanged = ['static bool CheckMacPerms(', 'uint32_t CheckPermissions(',
             'static std::optional<uint32_t> PropertySet(',
             'bool CheckControlPropertyPerms(', 'std::optional<uint32_t> HandlePropertySet(',
             'static void handle_property_set_fd(']
if os.environ.get('ROYD_ANDROID15_PROPERTY_PEER_SOURCE'):
    applied = (Path(os.environ['ROYD_ANDROID15_PROPERTY_PEER_SOURCE']) / relative).read_text()
    for method in [signature, *unchanged]:
        assert block(applied, method) == block(patched, method), method

harness = r'''
#include <atomic>
#include <cassert>
#include <cerrno>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <vector>
#include <sys/socket.h>
#include <unistd.h>
static const char* marker;
static int peerError, probeError, enabled;
static std::atomic<int> peers{0}, probes{0}, frees{0}, warnings{0};
static bool macAllowed = true, addAllowed = true;
static int macCalls, notifications, persists;
static ucred expectedCred{42, 1000, 1000};
static const char* mockGetenv(const char* name) {
    assert(!strcmp(name, "ROYD_CONTAINER")); return marker;
}
static int mockAccess(const char* path, int mode) {
    assert(!strcmp(path, "/sys/fs/selinux/enforce") && mode == F_OK);
    probes++; errno = probeError; return probeError ? -1 : 0;
}
static int getpeercon(int fd, char** context) {
    assert(fd == 17); peers++;
    if (peerError) { errno = peerError; return -1; }
    *context = strdup("u:r:example:s0"); assert(*context); return 0;
}
static void freecon(char* context) { frees++; free(context); }
static int is_selinux_enabled() { return enabled; }
struct Log {
    void operator<<(const char* text) {
        assert(!strcmp(text, "ROYD: property peer security context unavailable")); warnings++;
    }
};
#define LOG(level) Log()
#define getenv mockGetenv
#define access mockAccess
class SocketConnection {
    struct { int get() const { return 17; } } socket_;
public:
    PEER_METHOD
};
struct PropertyAuditData { const ucred* cr; const char* name; };
static std::mutex selinux_check_access_lock;
static int selinux_check_access(const char* source, const char* target,
                               const char* cls, const char* perm, void* data) {
    assert(source && target && !strcmp(cls, "property_service") && !strcmp(perm, "set"));
    auto* audit = static_cast<PropertyAuditData*>(data);
    assert(audit && audit->name && audit->cr);
    assert(audit->cr->pid == expectedCred.pid && audit->cr->uid == expectedCred.uid &&
           audit->cr->gid == expectedCred.gid);
    macCalls++; return macAllowed ? 0 : -1;
}
MAC_METHOD
static bool StartsWith(const std::string& s, const char* prefix) { return s.rfind(prefix, 0) == 0; }
struct PropertyInfo {
    void GetPropertyInfo(const char*, const char** context, const char** type) const {
        *context = "u:object_r:default_prop:s0"; *type = "bool";
    }
};
static PropertyInfo info;
static PropertyInfo* property_info_area = &info;
static bool IsLegalPropertyName(const std::string& name) { return !name.empty() && name != "bad name"; }
static bool CheckType(const char* type, const std::string& value) {
    assert(!strcmp(type, "bool")); return value == "true" || value == "false";
}
template<class... Args> static std::string StringPrintf(const char*, Args...) { return "control denied"; }
enum : uint32_t { PROP_SUCCESS, PROP_ERROR_INVALID_NAME, PROP_ERROR_HANDLE_CONTROL_MESSAGE,
                 PROP_ERROR_PERMISSION_DENIED, PROP_ERROR_INVALID_VALUE,
                 PROP_ERROR_READ_ONLY_PROPERTY, PROP_ERROR_SET_FAILED };
CONTROL_METHOD
PERMISSIONS_METHOD
struct LegalValue {
    bool valid;
    bool ok() const { return valid; }
    struct Error { std::string message() const { return "invalid value"; } };
    Error error() const { return {}; }
};
static LegalValue IsLegalPropertyValue(const std::string&, const std::string& value) {
    return {value.size() < 92};
}
struct prop_info { std::string value; };
static std::map<std::string, prop_info> properties;
static const prop_info* __system_property_find(const char* name) {
    auto found = properties.find(name); return found == properties.end() ? nullptr : &found->second;
}
static int __system_property_add(const char* name, size_t, const char* value, size_t) {
    if (!addAllowed) return -1;
    properties[name] = {value}; return 0;
}
static void __system_property_update(prop_info* p, const char* value, size_t) { p->value = value; }
static bool persistent_properties_loaded;
struct PersistWriteThread {
    int writes = 0;
    void Write(const std::string&, const std::string&, SocketConnection) { writes++; }
};
static std::unique_ptr<PersistWriteThread> persist_write_thread;
static void WritePersistentProperty(const std::string&, const std::string&) { persists++; }
static void NotifyPropertyChange(const std::string&, const std::string&) { notifications++; }
SET_METHOD
int main() {
    int cases = 0;
    for (const char* value : {static_cast<const char*>(nullptr), "", "0", "01", "1", "1x"}) {
        for (int pe : {0, ENOPROTOOPT, ENOENT, EACCES, EIO, ENOMEM, EBADF, ERANGE, EINVAL, ENOTCONN}) {
            for (int se : {0, ENOENT, EACCES, EIO, ENOTDIR}) {
                for (int state : {-1, 0, 1}) {
                    marker = value; peerError = pe; probeError = se; enabled = state;
                    probes = frees = peers = 0;
                    std::string context = "previous-context";
                    bool gate = pe == ENOPROTOOPT && value && !strcmp(value, "1") && se == ENOENT && state == 0;
                    errno = 0; bool result = SocketConnection().GetSourceContext(&context);
                    assert(result == (pe == 0 || gate));
                    assert(context == (pe == 0 ? "u:r:example:s0" : gate ? "" : "previous-context"));
                    assert(peers == 1 && frees == int(pe == 0));
                    assert(probes == int(pe == ENOPROTOOPT && value && !strcmp(value, "1")));
                    if (!result) assert(errno == pe);
                    cases++;
                }
            }
        }
    }
    assert(warnings == 1);
    marker = "1"; peerError = ENOPROTOOPT; probeError = ENOENT; enabled = 0;
    std::vector<std::thread> threads;
    for (int i = 0; i < 16; i++) threads.emplace_back([] {
        std::string context; assert(SocketConnection().GetSourceContext(&context) && context.empty());
    });
    for (auto& t : threads) t.join();
    assert(warnings == 1);
    SocketConnection socket;
    std::string context, error;
    assert(socket.GetSourceContext(&context) && context.empty());
    for (uid_t uid : {0, 1000, 10001}) {
        expectedCred = {42, uid, uid};
        assert(CheckPermissions("ro.cold_boot_done", "true", context, expectedCred, &error) == PROP_SUCCESS);
        assert(CheckPermissions("ro.cold_boot_done", "bad", context, expectedCred, &error) == PROP_ERROR_INVALID_VALUE);
        assert(CheckPermissions("bad name", "true", context, expectedCred, &error) == PROP_ERROR_INVALID_NAME);
        macAllowed = false;
        assert(CheckPermissions("ro.cold_boot_done", "true", context, expectedCred, &error) == PROP_ERROR_PERMISSION_DENIED);
        assert(CheckPermissions("ctl.start", "zygote", context, expectedCred, &error) == PROP_ERROR_HANDLE_CONTROL_MESSAGE);
        macAllowed = true;
        assert(CheckPermissions("ctl.start", "zygote", context, expectedCred, &error) == PROP_SUCCESS);
    }
    assert(macCalls > 0);
    // The unchanged writer still enforces read-only properties, value bounds and failures.
    assert(PropertySet("ro.cold_boot_done", "true", &socket, &error) == PROP_SUCCESS);
    assert(PropertySet("ro.cold_boot_done", "false", &socket, &error) == PROP_ERROR_READ_ONLY_PROPERTY);
    assert(properties.at("ro.cold_boot_done").value == "true");
    assert(PropertySet("bad name", "true", &socket, &error) == PROP_ERROR_INVALID_NAME);
    assert(PropertySet("test", std::string(92, 'x'), &socket, &error) == PROP_ERROR_INVALID_VALUE);
    addAllowed = false;
    assert(PropertySet("new", "true", &socket, &error) == PROP_ERROR_SET_FAILED);
    addAllowed = true;
    assert(PropertySet("persist.test", "true", &socket, &error) == PROP_SUCCESS && persists == 0);
    persistent_properties_loaded = true;
    assert(PropertySet("persist.test", "false", &socket, &error) == PROP_SUCCESS && persists == 1);
    persist_write_thread = std::make_unique<PersistWriteThread>();
    assert(!PropertySet("persist.test", "true", &socket, &error).has_value());
    assert(persist_write_thread->writes == 1 && persists == 1 && notifications == 3);
    printf("Property peer-context contract passed: %d gate/error cases, bounded concurrent logging, caller credentials, MAC/type/control/write-once/persistence checks\n", cases);
}
'''
for token, method in [('PEER_METHOD', signature), ('MAC_METHOD', unchanged[0]),
                      ('PERMISSIONS_METHOD', unchanged[1]), ('SET_METHOD', unchanged[2]),
                      ('CONTROL_METHOD', unchanged[3])]:
    harness = harness.replace(token, block(patched, method))
compiler = os.environ.get('CXX', 'c++')


def run(name, text, must_pass):
    cpp = temporary / (name + '.cpp')
    binary = temporary / name
    cpp.write_text(text)
    warnings = ['-Wall', '-Wextra', '-Werror'] if must_pass else []
    subprocess.run([compiler, '-std=c++17', *warnings, '-pthread',
                    str(cpp), '-o', str(binary)], check=True)
    result = subprocess.run([str(binary)], capture_output=True, text=True)
    assert (result.returncode == 0) == must_pass, (name, result.stderr)
    if must_pass:
        print(result.stdout, end='')


run('property-peer-context', harness, True)
for name, mutant in [
    ('stock-lookup', harness.replace(block(patched, signature), block(stock, signature))),
    ('all-lookup-errors', harness.replace('context_errno == ENOPROTOOPT', 'context_errno != 0')),
    ('all-probe-errors', harness.replace('errno == ENOENT', 'errno != 0')),
    ('selinux-enabled', harness.replace('is_selinux_enabled() == 0', 'is_selinux_enabled() <= 1')),
    ('lost-errno', harness.replace('errno = context_errno;', 'errno = EACCES;')),
]:
    assert mutant != harness, name
    run(name, mutant, False)
print('Mutation controls passed: stock failure, other lookup/probe errors, enabled SELinux and lost errno rejected')
