/* Copyright 2026 The royd Authors. SPDX-License-Identifier: Apache-2.0 */
#include <cassert>
#include <cerrno>
#include <cstring>
#include <map>
#include <stdexcept>
#include <string>
#include <vector>
#include <unistd.h>

static std::map<std::string, std::string> files;
static std::vector<std::string> reads;
static std::string parsed, deniedPath;
static int entered, noNewPrivs, filters, logging;
static bool failWrite;
struct Logger {
    bool fatal;
    explicit Logger(const char* level) : fatal(!strcmp(level, "FATAL")) {}
    template<class T> Logger& operator<<(const T&) { return *this; }
    ~Logger() noexcept(false) { if (fatal) throw std::runtime_error("required load failed"); }
};
#define LOG(level) Logger(#level)
#define PLOG(level) Logger(#level)
namespace android::base {
class unique_fd {
    int fd;
public:
    explicit unique_fd(int value) : fd(value) {}
    ~unique_fd() { if (fd >= 0) close(fd); }
    int get() const { return fd; }
    int release() { int value = fd; fd = -1; return value; }
};
static bool ReadFileToString(const std::string& path, std::string* text, bool follow) {
    assert(!follow);
    reads.push_back(path);
    if (path == deniedPath) { errno = EACCES; return false; }
    if (!files.count(path)) { errno = ENOENT; return false; }
    *text = files.at(path);
    return true;
}
static bool WriteStringToFd(const std::string& text, int fd) {
    if (failWrite) return false;
    return write(fd, text.data(), text.size()) == static_cast<ssize_t>(text.size());
}
}
static int* minijail_new() { return new int(0); }
class ScopedMinijail {
    int* jail;
public:
    explicit ScopedMinijail(int* value) : jail(value) {}
    ~ScopedMinijail() { delete jail; }
    explicit operator bool() const { return jail != nullptr; }
    int* get() const { return jail; }
};
static void minijail_no_new_privs(int*) { ++noNewPrivs; }
static void minijail_log_seccomp_filter_failures(int*) { ++logging; }
static void minijail_use_seccomp_filter(int*) { ++filters; }
static void minijail_parse_seccomp_filters_from_fd(int*, int fd) {
    char data[1024];
    ssize_t size;
    while ((size = read(fd, data, sizeof(data))) > 0) parsed.append(data, size);
    assert(size == 0);
    close(fd);
}
static void minijail_enter(int*) { ++entered; }

// Execute the complete applied loader, including its real pipe composition.
#include ROYD_LOADER_SOURCE

static void reset() {
    files = {{"/stock", "read: 1\n"}, {"/vendor", "close: 1\n"}, {"/required", "memfd_create: arg1 == 9\n"}};
    reads.clear(); parsed.clear(); deniedPath.clear();
    entered = noNewPrivs = filters = logging = 0;
    failWrite = false;
}
static void success(const std::string& expected) {
    assert(parsed == expected);
    assert(entered == 1 && noNewPrivs == 1 && filters == 1 && logging == 1);
}
int main() {
    reset();
    android::SetUpMinijail("/stock", "/vendor");
    success(files["/stock"] + "\n" + files["/vendor"]);
    assert((reads == std::vector<std::string>{"/stock", "/vendor"}));
    reset();
    android::SetUpMinijailWithRequiredPolicy("/stock", "/vendor", "/required");
    success(files["/stock"] + "\n" + files["/vendor"] + "\n" + files["/required"]);
    reset(); files.erase("/vendor");
    android::SetUpMinijailWithRequiredPolicy("/stock", "/vendor", "/required");
    success(files["/stock"] + "\n" + files["/required"]);
    reset();
    android::SetUpMinijailList("/stock", {"/vendor", "/required"});
    success(files["/stock"] + "\n" + files["/vendor"] + "\n" + files["/required"]);
    for (const char* failed : {"/stock", "/required", "/permission", "/pipe"}) {
        reset();
        if (!strcmp(failed, "/permission")) deniedPath = "/required";
        else if (!strcmp(failed, "/pipe")) failWrite = true;
        else files.erase(failed);
        bool caught = false;
        try { android::SetUpMinijailWithRequiredPolicy("/stock", "/vendor", "/required"); }
        catch (const std::runtime_error&) { caught = true; }
        assert(caught && entered == 0 && noNewPrivs == 0 && filters == 0 && parsed.empty());
    }
}
