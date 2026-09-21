#include "Allocator.h"

#include "../common/royd_buffer.h"

#include <aidl/android/hardware/graphics/allocator/AllocationError.h>
#include <aidl/android/hardware/graphics/common/BufferUsage.h>
#include <aidl/android/hardware/graphics/common/BlendMode.h>
#include <aidl/android/hardware/graphics/common/Dataspace.h>
#include <aidl/android/hardware/graphics/common/PixelFormat.h>
#include <aidlcommonsupport/NativeHandle.h>
#include <cutils/native_handle.h>
#include <linux/memfd.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <unistd.h>

#include <atomic>
#include <cerrno>
#include <cstring>
#include <limits>
#include <string>

namespace royd::graphics {
namespace {

using aidl::android::hardware::graphics::allocator::AllocationError;
using aidl::android::hardware::graphics::allocator::AllocationResult;
using aidl::android::hardware::graphics::allocator::BufferDescriptorInfo;
using aidl::android::hardware::graphics::common::BlendMode;
using aidl::android::hardware::graphics::common::BufferUsage;
using aidl::android::hardware::graphics::common::Dataspace;
using aidl::android::hardware::graphics::common::PixelFormat;

std::atomic<uint64_t> gNextBufferId{1};

ndk::ScopedAStatus allocationError(AllocationError error) {
    return ndk::ScopedAStatus::fromServiceSpecificError(static_cast<int32_t>(error));
}

uint32_t bytesPerPixel(PixelFormat format) {
    switch (format) {
        case PixelFormat::RGBA_8888:
        case PixelFormat::RGBX_8888:
        case PixelFormat::BGRA_8888:
        case PixelFormat::RGBA_1010102:
            return 4;
        case PixelFormat::RGB_888:
            return 3;
        case PixelFormat::RGB_565:
            return 2;
        case PixelFormat::RGBA_FP16:
            return 8;
        case PixelFormat::BLOB:
        case PixelFormat::YV12:
            return 1;
        default:
            return 0;
    }
}

bool usageSupported(BufferUsage usage) {
    const uint64_t value = static_cast<uint64_t>(usage);
    const uint64_t protectedBit = static_cast<uint64_t>(BufferUsage::PROTECTED);
    if ((value & protectedBit) != 0) {
        return false;
    }

    // Keep the advertised contract deliberately narrow. These usages cover CPU
    // access, software RenderEngine buffers and SurfaceFlinger client targets.
    // Other standard usage bits are rejected until royd implements and validates
    // their stronger semantics.
    const uint64_t known = static_cast<uint64_t>(BufferUsage::CPU_READ_MASK) |
            static_cast<uint64_t>(BufferUsage::CPU_WRITE_MASK) |
            static_cast<uint64_t>(BufferUsage::GPU_TEXTURE) |
            static_cast<uint64_t>(BufferUsage::GPU_RENDER_TARGET) |
            static_cast<uint64_t>(BufferUsage::COMPOSER_OVERLAY) |
            static_cast<uint64_t>(BufferUsage::COMPOSER_CLIENT_TARGET) |
            static_cast<uint64_t>(BufferUsage::COMPOSER_CURSOR);
    return (value & ~known) == 0;
}

bool descriptorSupported(const BufferDescriptorInfo& descriptor) {
    if (descriptor.width <= 0 || descriptor.height <= 0 || descriptor.layerCount <= 0) {
        return false;
    }
    if (descriptor.format == PixelFormat::BLOB && descriptor.height != 1) {
        return false;
    }
    if (descriptor.format == PixelFormat::YV12 &&
        ((descriptor.width & 1) != 0 || (descriptor.height & 1) != 0 || descriptor.layerCount != 1)) {
        return false;
    }
    return descriptor.additionalOptions.empty() && bytesPerPixel(descriptor.format) != 0 &&
            usageSupported(descriptor.usage);
}

struct AllocationLayout {
    uint64_t pixelSize;
    uint32_t stride;
    uint32_t bytesPerPixel;
};

bool align16(uint64_t value, uint64_t* aligned) {
    uint64_t withPadding;
    if (__builtin_add_overflow(value, uint64_t{15}, &withPadding)) {
        return false;
    }
    *aligned = withPadding & ~uint64_t{15};
    return true;
}

bool calculateLayout(const BufferDescriptorInfo& descriptor, AllocationLayout* layout,
                     uint64_t* totalSize) {
    uint64_t pixelSize;
    uint64_t stride;
    const uint32_t bpp = bytesPerPixel(descriptor.format);

    if (descriptor.format == PixelFormat::YV12) {
        uint64_t chromaStride;
        uint64_t ySize;
        uint64_t chromaSize;
        uint64_t chromaTotal;
        if (!align16(static_cast<uint64_t>(descriptor.width), &stride) ||
            !align16(stride / 2, &chromaStride) ||
            __builtin_mul_overflow(stride, static_cast<uint64_t>(descriptor.height), &ySize) ||
            __builtin_mul_overflow(chromaStride, static_cast<uint64_t>(descriptor.height / 2),
                                   &chromaSize) ||
            __builtin_mul_overflow(chromaSize, uint64_t{2}, &chromaTotal) ||
            __builtin_add_overflow(ySize, chromaTotal, &pixelSize)) {
            return false;
        }
    } else {
        uint64_t rowBytes;
        uint64_t layerSize;
        stride = static_cast<uint64_t>(descriptor.width);
        if (__builtin_mul_overflow(stride, static_cast<uint64_t>(bpp), &rowBytes) ||
            __builtin_mul_overflow(rowBytes, static_cast<uint64_t>(descriptor.height), &layerSize) ||
            __builtin_mul_overflow(layerSize, static_cast<uint64_t>(descriptor.layerCount),
                                   &pixelSize)) {
            return false;
        }
    }

    if (stride > std::numeric_limits<uint32_t>::max() || descriptor.reservedSize < 0 ||
        __builtin_add_overflow(kPixelOffset, pixelSize, totalSize) ||
        __builtin_add_overflow(*totalSize, static_cast<uint64_t>(descriptor.reservedSize),
                               totalSize) ||
        *totalSize > static_cast<uint64_t>(std::numeric_limits<off_t>::max())) {
        return false;
    }
    *layout = AllocationLayout{pixelSize, static_cast<uint32_t>(stride), bpp};
    return true;
}

int createMemfd() {
#ifdef SYS_memfd_create
    return static_cast<int>(syscall(SYS_memfd_create, "royd-graphics", MFD_CLOEXEC));
#else
    errno = ENOSYS;
    return -1;
#endif
}

native_handle_t* allocateOne(const BufferDescriptorInfo& descriptor, int32_t* stride) {
    AllocationLayout layout = {};
    uint64_t totalSize;
    if (!calculateLayout(descriptor, &layout, &totalSize)) {
        return nullptr;
    }

    int fd = createMemfd();
    if (fd < 0) {
        return nullptr;
    }
    if (ftruncate(fd, static_cast<off_t>(totalSize)) != 0) {
        close(fd);
        return nullptr;
    }

    void* mapping = mmap(nullptr, kPixelOffset, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (mapping == MAP_FAILED) {
        close(fd);
        return nullptr;
    }

    auto* header = static_cast<RoydBufferHeader*>(mapping);
    std::memset(header, 0, sizeof(*header));
    header->magic = kHeaderMagic;
    header->version = kHeaderVersion;
    header->bufferId = (static_cast<uint64_t>(getpid()) << 32) | gNextBufferId.fetch_add(1);
    header->usage = static_cast<uint64_t>(descriptor.usage);
    header->allocationSize = layout.pixelSize + static_cast<uint64_t>(descriptor.reservedSize);
    header->pixelSize = layout.pixelSize;
    header->reservedSize = static_cast<uint64_t>(descriptor.reservedSize);
    header->reservedOffset = kPixelOffset + layout.pixelSize;
    header->width = static_cast<uint32_t>(descriptor.width);
    header->height = static_cast<uint32_t>(descriptor.height);
    header->layerCount = static_cast<uint32_t>(descriptor.layerCount);
    header->format = static_cast<int32_t>(descriptor.format);
    header->stride = layout.stride;
    header->bytesPerPixel = layout.bytesPerPixel;
    header->dataspace = static_cast<int32_t>(Dataspace::UNKNOWN);
    header->blendMode = static_cast<int32_t>(BlendMode::NONE);
    for (size_t i = 0; i < sizeof(header->name) - 1 && i < descriptor.name.size(); ++i) {
        const auto byte = static_cast<unsigned char>(descriptor.name[i]);
        if (byte == 0) {
            break;
        }
        header->name[i] = static_cast<char>(byte);
    }
    msync(mapping, sizeof(*header), MS_SYNC);
    munmap(mapping, kPixelOffset);

    native_handle_t* handle = native_handle_create(kHandleFds, kHandleInts);
    if (handle == nullptr) {
        close(fd);
        return nullptr;
    }
    handle->data[0] = fd;
    handle->data[1] = kHandleMagic;
    handle->data[2] = kHandleVersion;
    *stride = static_cast<int32_t>(layout.stride);
    return handle;
}

}  // namespace

ndk::ScopedAStatus Allocator::allocate(const std::vector<uint8_t>&, int32_t, AllocationResult*) {
    return allocationError(AllocationError::BAD_DESCRIPTOR);
}

ndk::ScopedAStatus Allocator::allocate2(const BufferDescriptorInfo& descriptor, int32_t count,
                                        AllocationResult* result) {
    if (result == nullptr || count <= 0 || !descriptorSupported(descriptor)) {
        return allocationError(AllocationError::UNSUPPORTED);
    }

    result->buffers.clear();
    result->buffers.reserve(static_cast<size_t>(count));
    for (int32_t i = 0; i < count; ++i) {
        native_handle_t* handle = allocateOne(descriptor, &result->stride);
        if (handle == nullptr) {
            result->buffers.clear();
            return allocationError(AllocationError::NO_RESOURCES);
        }
        result->buffers.push_back(::android::dupToAidl(handle));
        native_handle_close(handle);
        native_handle_delete(handle);
    }
    return ndk::ScopedAStatus::ok();
}

ndk::ScopedAStatus Allocator::isSupported(const BufferDescriptorInfo& descriptor, bool* supported) {
    if (supported == nullptr) {
        return allocationError(AllocationError::BAD_DESCRIPTOR);
    }
    *supported = descriptorSupported(descriptor);
    return ndk::ScopedAStatus::ok();
}

ndk::ScopedAStatus Allocator::getIMapperLibrarySuffix(std::string* suffix) {
    if (suffix == nullptr) {
        return allocationError(AllocationError::BAD_DESCRIPTOR);
    }
    *suffix = "royd";
    return ndk::ScopedAStatus::ok();
}

}  // namespace royd::graphics
