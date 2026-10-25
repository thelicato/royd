/* Copyright 2026 The royd Authors. SPDX-License-Identifier: Apache-2.0 */
#include <cassert>
#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <sys/stat.h>
#include <string>

static const char* container;
static int statError, statCalls, propertyCalls;
static bool treble, memfd;
[[maybe_unused]] static const char* fakeGetenv(const char* key) {
    assert(!strcmp(key, "ROYD_CONTAINER"));
    return container;
}
[[maybe_unused]] static int fakeStat(const char* path, struct stat*) {
    assert(!strcmp(path, "/sys/fs/selinux/enforce"));
    ++statCalls;
    errno = statError ? statError : ENOENT;  // Stale errno after success must not enable the gate.
    return statError ? -1 : 0;
}
static bool fakeProperty(const std::string& key, bool fallback) {
    assert(!fallback);
    ++propertyCalls;
    if (key == "ro.treble.enabled") return treble;
    assert(key == "sys.use_memfd");
    return memfd;
}
#define getenv(...) fakeGetenv(__VA_ARGS__)
#define stat(...) fakeStat(__VA_ARGS__)
#include "RoydMediaExtractorPolicy.h"
#undef stat
#undef getenv

int main() {
    const char* values[] = {nullptr, "", "0", "1", "01", "true"};
    const int errors[] = {0, ENOENT, EACCES, EIO, ENOTDIR, ESTALE};
#if defined(__x86_64__)
    constexpr bool target = true;
#else
    constexpr bool target = false;
#endif
    int cases = 0;
    for (const char* value : values) for (int error : errors)
        for (bool t : {false, true}) for (bool m : {false, true}) {
            container = value; statError = error; treble = t; memfd = m;
            statCalls = propertyCalls = 0;
            const char* stock = "/stock/unchanged.policy";
            const char* result = royd::mediaExtractorSeccompPolicy(stock);
            bool explicitContainer = value && !strcmp(value, "1");
            bool selected = target && explicitContainer && error == ENOENT && t && m;
            if (selected) {
                assert(!strcmp(result, "/vendor/etc/seccomp_policy/royd-mediaextractor-x86_64.policy"));
            } else {
                assert(result == stock);
            }
            assert(statCalls == (target && explicitContainer ? 1 : 0));
            assert(propertyCalls == (target && explicitContainer && error == ENOENT ? (t ? 2 : 1) : 0));
            ++cases;
        }
    assert(cases == 144);
}
