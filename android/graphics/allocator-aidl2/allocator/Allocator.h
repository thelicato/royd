#pragma once

#include <aidl/android/hardware/graphics/allocator/BnAllocator.h>

namespace royd::graphics {

class Allocator final : public aidl::android::hardware::graphics::allocator::BnAllocator {
  public:
    ndk::ScopedAStatus allocate(const std::vector<uint8_t>& descriptor, int32_t count,
                                aidl::android::hardware::graphics::allocator::AllocationResult* result) override;
    ndk::ScopedAStatus allocate2(
            const aidl::android::hardware::graphics::allocator::BufferDescriptorInfo& descriptor,
            int32_t count,
            aidl::android::hardware::graphics::allocator::AllocationResult* result) override;
    ndk::ScopedAStatus isSupported(
            const aidl::android::hardware::graphics::allocator::BufferDescriptorInfo& descriptor,
            bool* supported) override;
    ndk::ScopedAStatus getIMapperLibrarySuffix(std::string* suffix) override;
};

}  // namespace royd::graphics
