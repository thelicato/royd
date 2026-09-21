#include "Allocator.h"

#include <aidl/android/hardware/graphics/allocator/IAllocator.h>
#include <android/binder_manager.h>
#include <android/binder_process.h>
#include <log/log.h>

#include <cstdlib>
#include <memory>
#include <string>

int main() {
    using aidl::android::hardware::graphics::allocator::IAllocator;

    ABinderProcess_setThreadPoolMaxThreadCount(0);
    auto allocator = ndk::SharedRefBase::make<royd::graphics::Allocator>();
    const std::string instance = std::string(IAllocator::descriptor) + "/default";
    if (AServiceManager_addService(allocator->asBinder().get(), instance.c_str()) != STATUS_OK) {
        ALOGE("failed to register %s", instance.c_str());
        return EXIT_FAILURE;
    }
    ABinderProcess_joinThreadPool();
    return EXIT_FAILURE;
}
