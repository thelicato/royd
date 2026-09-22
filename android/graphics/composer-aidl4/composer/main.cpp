#include "Composer.h"

#include <android/binder_manager.h>
#include <android/binder_process.h>
#include <log/log.h>

#include <cstdlib>
#include <string>

using royd::graphics::composer::Composer;
namespace c3 = aidl::android::hardware::graphics::composer3;

int main() {
    ABinderProcess_setThreadPoolMaxThreadCount(4);

    auto composer = ndk::SharedRefBase::make<Composer>();
    const std::string instance = std::string(c3::IComposer::descriptor) + "/default";
    if (AServiceManager_addService(composer->asBinder().get(), instance.c_str()) != STATUS_OK) {
        ALOGE("failed to register %s", instance.c_str());
        return EXIT_FAILURE;
    }

    ALOGI("registered %s", instance.c_str());
    ABinderProcess_joinThreadPool();
    return EXIT_FAILURE;
}
