#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
patch="$root/android/patches/android-15.0.0_r36/0052-surfaceflinger-honour-optional-display-identification.patch"
[ "$(grep -c '^diff --git ' "$patch")" -eq 1 ]
grep -Fq 'diff --git a/frameworks/native/services/surfaceflinger/DisplayHardware/AidlComposerHal.cpp' "$patch"
! grep -q '^-[^-]' "$patch"
! grep -Eq '^\+.*(outPort|outData|Permission|SELinux|SystemProperties|mAidlComposerClient)' "$patch"
composer="$root/android/graphics/composer-aidl4/composer/Composer.cpp"
identification=$(sed -n '/^ndk::ScopedAStatus ComposerClient::getDisplayIdentificationData(/,/^}/p' "$composer")
printf '%s\n' "$identification" | grep -Fq 'if (!isDisplay(display)) return badDisplay();'
printf '%s\n' "$identification" | grep -Fq 'return unsupported();'
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
cat >"$tmp/identification.cpp" <<'CPP'
#include <cassert>
#include <cstdint>
#include <string>
#include <vector>
enum class Error : int32_t { NONE = 0, UNSUPPORTED = 8 };
constexpr int32_t EX_SERVICE_SPECIFIC = -8;
using Display = int64_t;
struct Status {
    bool ok;
    int32_t exception, error;
    bool isOk() const { return ok; }
    int32_t getExceptionCode() const { return exception; }
    int32_t getServiceSpecificError() const { return error; }
    std::string getDescription() const { return "status detail"; }
};
struct AidlDisplayIdentification { int8_t port; std::vector<uint8_t> data; };
struct Client {
    Status status{true, 0, 0};
    AidlDisplayIdentification reply{};
    int calls = 0;
    int64_t lastDisplay = -1;
    Status getDisplayIdentificationData(int64_t display, AidlDisplayIdentification* output) {
        calls++;
        lastDisplay = display;
        *output = reply; // Even partial failure replies must not reach the caller.
        return status;
    }
};
template<class T> T translate(Display value) { return static_cast<T>(value); }
struct AidlComposer {
    Client* mAidlComposerClient;
    Error getDisplayIdentificationData(Display, uint8_t*, std::vector<uint8_t>*);
};
static int errors;
static void logError(const char* format, const char* description) {
    assert(std::string(format) == "getDisplayIdentificationData failed %s");
    assert(std::string(description) == "status detail");
    errors++;
}
#define ALOGE(format, description) logError(format, description)
CPP
awk '
  /^ Error AidlComposer::getDisplayIdentificationData/ { copy = 1 }
  copy && /^[ +]/ { print substr($0, 2) }
' "$patch" >>"$tmp/identification.cpp"
cat >>"$tmp/identification.cpp" <<'CPP'
int main() {
    Client client;
    AidlComposer composer{&client};
    for (int64_t display : {int64_t{0}, int64_t{1}, int64_t{9223372036854775807LL}}) {
        for (int32_t exception : {-8, -1, -3, -129, 0}) {
            for (int32_t error : {-1, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9}) {
                client.status = {false, exception, error};
                client.reply = {42, {0, 255, 128}};
                uint8_t port = 17;
                std::vector<uint8_t> data{99, 100};
                errors = 0;
                const int before = client.calls;
                const auto result = composer.getDisplayIdentificationData(display, &port, &data);
                // This diagnostic-only fix preserves the adapter's stock error translation.
                assert(result == static_cast<Error>(error));
                assert(errors == int(exception != EX_SERVICE_SPECIFIC || error != 8));
                assert(port == 17 && (data == std::vector<uint8_t>{99, 100}));
                assert(client.calls == before + 1 && client.lastDisplay == display);
            }
        }
        for (int8_t replyPort : {int8_t{0}, int8_t{127}, int8_t{-128}, int8_t{-1}}) {
            for (auto replyData : {std::vector<uint8_t>{}, std::vector<uint8_t>{0, 255, 128}}) {
                client.status = {true, 0, 0};
                client.reply = {replyPort, replyData};
                uint8_t port = 17;
                std::vector<uint8_t> data{99, 100};
                errors = 0;
                const int before = client.calls;
                assert(composer.getDisplayIdentificationData(display, &port, &data) == Error::NONE);
                assert(port == static_cast<uint8_t>(replyPort) && data == replyData);
                assert(errors == 0 && client.calls == before + 1 && client.lastDisplay == display);
            }
        }
    }
}
CPP
c++ -std=c++17 -Wall -Wextra -Werror "$tmp/identification.cpp" -o "$tmp/identification"
"$tmp/identification"
printf '%s\n' 'Android 15 optional display-identification contract passed'
