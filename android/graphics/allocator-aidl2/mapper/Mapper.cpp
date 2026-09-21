#include "../common/royd_buffer.h"

#include <aidl/android/hardware/graphics/common/BlendMode.h>
#include <aidl/android/hardware/graphics/common/BufferUsage.h>
#include <aidl/android/hardware/graphics/common/Cta861_3.h>
#include <aidl/android/hardware/graphics/common/Dataspace.h>
#include <aidl/android/hardware/graphics/common/ExtendableType.h>
#include <aidl/android/hardware/graphics/common/PixelFormat.h>
#include <aidl/android/hardware/graphics/common/PlaneLayout.h>
#include <aidl/android/hardware/graphics/common/PlaneLayoutComponent.h>
#include <aidl/android/hardware/graphics/common/Rect.h>
#include <aidl/android/hardware/graphics/common/Smpte2086.h>
#include <aidl/android/hardware/graphics/common/StandardMetadataType.h>
#include <android/hardware/graphics/mapper/IMapper.h>
#include <android/hardware/graphics/mapper/utils/IMapperMetadataTypes.h>
#include <android/hardware/graphics/mapper/utils/IMapperProvider.h>
#include <cutils/native_handle.h>
#include <sync/sync.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <array>
#include <cerrno>
#include <cstdint>
#include <cstring>
#include <mutex>
#include <optional>
#include <set>
#include <string>
#include <string_view>
#include <type_traits>
#include <unordered_map>
#include <utility>
#include <vector>

namespace royd::graphics {
namespace {

using aidl::android::hardware::graphics::common::BlendMode;
using aidl::android::hardware::graphics::common::BufferUsage;
using aidl::android::hardware::graphics::common::Cta861_3;
using aidl::android::hardware::graphics::common::Dataspace;
using aidl::android::hardware::graphics::common::ExtendableType;
using aidl::android::hardware::graphics::common::PixelFormat;
using aidl::android::hardware::graphics::common::PlaneLayout;
using aidl::android::hardware::graphics::common::PlaneLayoutComponent;
using aidl::android::hardware::graphics::common::Rect;
using aidl::android::hardware::graphics::common::Smpte2086;
using aidl::android::hardware::graphics::common::StandardMetadataType;
using android::hardware::graphics::mapper::StandardMetadata;

constexpr char kStandardMetadataName[] = "android.hardware.graphics.common.StandardMetadataType";
constexpr char kCompressionName[] = "android.hardware.graphics.common.Compression";
constexpr char kInterlacedName[] = "android.hardware.graphics.common.Interlaced";
constexpr char kChromaSitingName[] = "android.hardware.graphics.common.ChromaSiting";
constexpr char kPlaneComponentName[] = "android.hardware.graphics.common.PlaneLayoutComponentType";

constexpr int64_t kPlaneComponentY = 1 << 0;
constexpr int64_t kPlaneComponentCb = 1 << 1;
constexpr int64_t kPlaneComponentCr = 1 << 2;
constexpr int64_t kPlaneComponentR = 1 << 10;
constexpr int64_t kPlaneComponentG = 1 << 11;
constexpr int64_t kPlaneComponentB = 1 << 12;
constexpr int64_t kPlaneComponentRaw = 1 << 20;
constexpr int64_t kPlaneComponentA = 1LL << 30;

struct Mapping {
    void* base = MAP_FAILED;
    size_t size = 0;
    uint32_t locks = 0;
};

bool validateHandle(const native_handle_t* handle, RoydBufferHeader* outHeader = nullptr,
                    size_t* outSize = nullptr) {
    if (handle == nullptr || handle->numFds != kHandleFds || handle->numInts != kHandleInts ||
        handle->data[1] != kHandleMagic || handle->data[2] != kHandleVersion || handle->data[0] < 0) {
        return false;
    }

    struct stat st = {};
    if (fstat(handle->data[0], &st) != 0 || st.st_size < static_cast<off_t>(kPixelOffset)) {
        return false;
    }

    RoydBufferHeader header = {};
    if (pread(handle->data[0], &header, sizeof(header), 0) != static_cast<ssize_t>(sizeof(header)) ||
        header.magic != kHeaderMagic || header.version != kHeaderVersion || header.width == 0 ||
        header.height == 0 || header.layerCount == 0 || header.bytesPerPixel == 0 ||
        header.reservedOffset < kPixelOffset || header.reservedOffset > static_cast<uint64_t>(st.st_size) ||
        header.reservedSize > static_cast<uint64_t>(st.st_size) - header.reservedOffset ||
        header.smpte2094_10Size > kDynamicHdrMetadataCapacity ||
        header.smpte2094_40Size > kDynamicHdrMetadataCapacity) {
        return false;
    }
    if (outHeader != nullptr) {
        *outHeader = header;
    }
    if (outSize != nullptr) {
        *outSize = static_cast<size_t>(st.st_size);
    }
    return true;
}

bool writeHeader(buffer_handle_t buffer, const RoydBufferHeader& header) {
    return pwrite(buffer->data[0], &header, sizeof(header), 0) == static_cast<ssize_t>(sizeof(header));
}

ExtendableType extension(std::string name, int64_t value) {
    ExtendableType type;
    type.name = std::move(name);
    type.value = value;
    return type;
}

PlaneLayoutComponent component(int64_t type, int64_t offset, int64_t size) {
    PlaneLayoutComponent result;
    result.type = extension(kPlaneComponentName, type);
    result.offsetInBits = offset;
    result.sizeInBits = size;
    return result;
}

constexpr uint32_t fourcc(char a, char b, char c, char d) {
    return static_cast<uint32_t>(static_cast<uint8_t>(a)) |
            (static_cast<uint32_t>(static_cast<uint8_t>(b)) << 8) |
            (static_cast<uint32_t>(static_cast<uint8_t>(c)) << 16) |
            (static_cast<uint32_t>(static_cast<uint8_t>(d)) << 24);
}

uint32_t drmFourccForFormat(PixelFormat format) {
    // DRM fourcc names describe the little-endian integer layout. For example,
    // Android RGBA_8888 bytes map to DRM_FORMAT_ABGR8888.
    switch (format) {
        case PixelFormat::RGBA_8888:
            return fourcc('A', 'B', '2', '4');
        case PixelFormat::RGBX_8888:
            return fourcc('X', 'B', '2', '4');
        case PixelFormat::BGRA_8888:
            return fourcc('A', 'R', '2', '4');
        case PixelFormat::RGB_888:
            return fourcc('B', 'G', '2', '4');
        case PixelFormat::RGB_565:
            return fourcc('B', 'G', '1', '6');
        case PixelFormat::RGBA_FP16:
            return fourcc('A', 'B', '4', 'H');
        case PixelFormat::RGBA_1010102:
            return fourcc('A', 'B', '3', '0');
        case PixelFormat::BLOB:
            return fourcc('R', '8', ' ', ' ');
        case PixelFormat::YV12:
            return fourcc('Y', 'V', '1', '2');
        default:
            return 0;
    }
}

std::vector<PlaneLayoutComponent> componentsFor(const RoydBufferHeader& header) {
    const auto format = static_cast<PixelFormat>(header.format);
    switch (format) {
        case PixelFormat::RGBA_8888:
            return {component(kPlaneComponentR, 0, 8), component(kPlaneComponentG, 8, 8),
                    component(kPlaneComponentB, 16, 8), component(kPlaneComponentA, 24, 8)};
        case PixelFormat::RGBX_8888:
            return {component(kPlaneComponentR, 0, 8), component(kPlaneComponentG, 8, 8),
                    component(kPlaneComponentB, 16, 8)};
        case PixelFormat::BGRA_8888:
            return {component(kPlaneComponentB, 0, 8), component(kPlaneComponentG, 8, 8),
                    component(kPlaneComponentR, 16, 8), component(kPlaneComponentA, 24, 8)};
        case PixelFormat::RGB_888:
            return {component(kPlaneComponentR, 0, 8), component(kPlaneComponentG, 8, 8),
                    component(kPlaneComponentB, 16, 8)};
        case PixelFormat::RGB_565:
            return {component(kPlaneComponentB, 0, 5), component(kPlaneComponentG, 5, 6),
                    component(kPlaneComponentR, 11, 5)};
        case PixelFormat::RGBA_FP16:
            return {component(kPlaneComponentR, 0, 16), component(kPlaneComponentG, 16, 16),
                    component(kPlaneComponentB, 32, 16), component(kPlaneComponentA, 48, 16)};
        case PixelFormat::RGBA_1010102:
            return {component(kPlaneComponentR, 0, 10), component(kPlaneComponentG, 10, 10),
                    component(kPlaneComponentB, 20, 10), component(kPlaneComponentA, 30, 2)};
        case PixelFormat::BLOB:
            return {component(kPlaneComponentRaw, 0, 8)};
        default:
            return {};
    }
}

std::vector<PlaneLayout> planeLayouts(const RoydBufferHeader& header) {
    if (static_cast<PixelFormat>(header.format) == PixelFormat::YV12) {
        const int64_t yStride = header.stride;
        const int64_t chromaStride = ((yStride / 2) + 15) & ~int64_t{15};
        const int64_t ySize = yStride * header.height;
        const int64_t chromaHeight = header.height / 2;
        const int64_t chromaSize = chromaStride * chromaHeight;

        PlaneLayout yPlane;
        yPlane.components = {component(kPlaneComponentY, 0, 8)};
        yPlane.offsetInBytes = 0;
        yPlane.sampleIncrementInBits = 8;
        yPlane.strideInBytes = yStride;
        yPlane.widthInSamples = header.width;
        yPlane.heightInSamples = header.height;
        yPlane.totalSizeInBytes = ySize;
        yPlane.horizontalSubsampling = 1;
        yPlane.verticalSubsampling = 1;

        PlaneLayout crPlane;
        crPlane.components = {component(kPlaneComponentCr, 0, 8)};
        crPlane.offsetInBytes = ySize;
        crPlane.sampleIncrementInBits = 8;
        crPlane.strideInBytes = chromaStride;
        crPlane.widthInSamples = header.width / 2;
        crPlane.heightInSamples = chromaHeight;
        crPlane.totalSizeInBytes = chromaSize;
        crPlane.horizontalSubsampling = 2;
        crPlane.verticalSubsampling = 2;

        PlaneLayout cbPlane = crPlane;
        cbPlane.components = {component(kPlaneComponentCb, 0, 8)};
        cbPlane.offsetInBytes = ySize + chromaSize;
        return {std::move(yPlane), std::move(crPlane), std::move(cbPlane)};
    }

    PlaneLayout plane;
    plane.components = componentsFor(header);
    plane.offsetInBytes = 0;
    plane.sampleIncrementInBits = static_cast<int64_t>(header.bytesPerPixel) * 8;
    plane.strideInBytes = static_cast<int64_t>(header.stride) * header.bytesPerPixel;
    plane.widthInSamples = header.width;
    plane.heightInSamples = header.height;
    plane.totalSizeInBytes = header.pixelSize;
    plane.horizontalSubsampling = 1;
    plane.verticalSubsampling = 1;
    return {std::move(plane)};
}

Smpte2086 readSmpte2086(const RoydBufferHeader& header) {
    Smpte2086 value;
    value.primaryRed.x = header.smpte2086[0];
    value.primaryRed.y = header.smpte2086[1];
    value.primaryGreen.x = header.smpte2086[2];
    value.primaryGreen.y = header.smpte2086[3];
    value.primaryBlue.x = header.smpte2086[4];
    value.primaryBlue.y = header.smpte2086[5];
    value.whitePoint.x = header.smpte2086[6];
    value.whitePoint.y = header.smpte2086[7];
    value.maxLuminance = header.smpte2086[8];
    value.minLuminance = header.smpte2086[9];
    return value;
}

void writeSmpte2086(RoydBufferHeader* header, const Smpte2086& value) {
    header->smpte2086[0] = value.primaryRed.x;
    header->smpte2086[1] = value.primaryRed.y;
    header->smpte2086[2] = value.primaryGreen.x;
    header->smpte2086[3] = value.primaryGreen.y;
    header->smpte2086[4] = value.primaryBlue.x;
    header->smpte2086[5] = value.primaryBlue.y;
    header->smpte2086[6] = value.whitePoint.x;
    header->smpte2086[7] = value.whitePoint.y;
    header->smpte2086[8] = value.maxLuminance;
    header->smpte2086[9] = value.minLuminance;
}

Cta861_3 readCta8613(const RoydBufferHeader& header) {
    Cta861_3 value;
    value.maxContentLightLevel = header.cta8613[0];
    value.maxFrameAverageLightLevel = header.cta8613[1];
    return value;
}

void writeCta8613(RoydBufferHeader* header, const Cta861_3& value) {
    header->cta8613[0] = value.maxContentLightLevel;
    header->cta8613[1] = value.maxFrameAverageLightLevel;
}

bool isAllZero(const ARect& rect) {
    return rect.left == 0 && rect.top == 0 && rect.right == 0 && rect.bottom == 0;
}

bool regionValid(const ARect& rect, const RoydBufferHeader& header) {
    if (isAllZero(rect)) {
        return true;
    }
    return rect.left >= 0 && rect.top >= 0 && rect.right > rect.left && rect.bottom > rect.top &&
            static_cast<uint32_t>(rect.right) <= header.width &&
            static_cast<uint32_t>(rect.bottom) <= header.height;
}

bool cpuUsageOnly(uint64_t usage) {
    const uint64_t mask = static_cast<uint64_t>(BufferUsage::CPU_READ_MASK) |
            static_cast<uint64_t>(BufferUsage::CPU_WRITE_MASK);
    return usage != 0 && (usage & ~mask) == 0;
}

std::string headerName(const RoydBufferHeader& header) {
    return std::string(header.name, strnlen(header.name, sizeof(header.name)));
}

constexpr std::array<StandardMetadataType, 23> kStandardTypes = {
        StandardMetadataType::BUFFER_ID,
        StandardMetadataType::NAME,
        StandardMetadataType::WIDTH,
        StandardMetadataType::HEIGHT,
        StandardMetadataType::LAYER_COUNT,
        StandardMetadataType::PIXEL_FORMAT_REQUESTED,
        StandardMetadataType::PIXEL_FORMAT_FOURCC,
        StandardMetadataType::PIXEL_FORMAT_MODIFIER,
        StandardMetadataType::USAGE,
        StandardMetadataType::ALLOCATION_SIZE,
        StandardMetadataType::PROTECTED_CONTENT,
        StandardMetadataType::COMPRESSION,
        StandardMetadataType::INTERLACED,
        StandardMetadataType::CHROMA_SITING,
        StandardMetadataType::PLANE_LAYOUTS,
        StandardMetadataType::CROP,
        StandardMetadataType::DATASPACE,
        StandardMetadataType::BLEND_MODE,
        StandardMetadataType::SMPTE2086,
        StandardMetadataType::CTA861_3,
        StandardMetadataType::SMPTE2094_10,
        StandardMetadataType::SMPTE2094_40,
        StandardMetadataType::STRIDE,
};

bool settable(StandardMetadataType type) {
    switch (type) {
        case StandardMetadataType::DATASPACE:
        case StandardMetadataType::BLEND_MODE:
        case StandardMetadataType::SMPTE2086:
        case StandardMetadataType::CTA861_3:
        case StandardMetadataType::SMPTE2094_10:
        case StandardMetadataType::SMPTE2094_40:
            return true;
        default:
            return false;
    }
}

std::array<AIMapper_MetadataTypeDescription, kStandardTypes.size()> makeDescriptions() {
    std::array<AIMapper_MetadataTypeDescription, kStandardTypes.size()> result{};
    for (size_t i = 0; i < result.size(); ++i) {
        result[i].metadataType.name = kStandardMetadataName;
        result[i].metadataType.value = static_cast<int64_t>(kStandardTypes[i]);
        result[i].description = nullptr;
        result[i].isGettable = true;
        result[i].isSettable = settable(kStandardTypes[i]);
    }
    return result;
}

}  // namespace

class Mapper final : public vendor::mapper::IMapperV5Impl {
  public:
    AIMapper_Error importBuffer(const native_handle_t* handle, buffer_handle_t* outBufferHandle) override {
        if (outBufferHandle == nullptr || !validateHandle(handle)) {
            return AIMAPPER_ERROR_BAD_BUFFER;
        }
        native_handle_t* cloned = native_handle_clone(handle);
        if (cloned == nullptr) {
            return AIMAPPER_ERROR_NO_RESOURCES;
        }
        {
            std::lock_guard<std::mutex> lock(mMutex);
            mImported.insert(cloned);
        }
        *outBufferHandle = cloned;
        return AIMAPPER_ERROR_NONE;
    }

    AIMapper_Error freeBuffer(buffer_handle_t buffer) override {
        Mapping mapping;
        {
            std::lock_guard<std::mutex> lock(mMutex);
            auto imported = mImported.find(buffer);
            if (imported == mImported.end()) {
                return AIMAPPER_ERROR_BAD_BUFFER;
            }
            auto mapped = mMappings.find(buffer);
            if (mapped != mMappings.end()) {
                mapping = mapped->second;
                mMappings.erase(mapped);
            }
            mImported.erase(imported);
        }
        if (mapping.base != MAP_FAILED) {
            munmap(mapping.base, mapping.size);
        }
        native_handle_close(const_cast<native_handle_t*>(buffer));
        native_handle_delete(const_cast<native_handle_t*>(buffer));
        return AIMAPPER_ERROR_NONE;
    }

    AIMapper_Error getTransportSize(buffer_handle_t buffer, uint32_t* outNumFds,
                                    uint32_t* outNumInts) override {
        if (outNumFds == nullptr || outNumInts == nullptr || !isImported(buffer)) {
            return AIMAPPER_ERROR_BAD_BUFFER;
        }
        *outNumFds = kHandleFds;
        *outNumInts = kHandleInts;
        return AIMAPPER_ERROR_NONE;
    }

    AIMapper_Error lock(buffer_handle_t buffer, uint64_t cpuUsage, ARect accessRegion,
                        int acquireFence, void** outData) override {
        RoydBufferHeader header = {};
        if (outData == nullptr || !cpuUsageOnly(cpuUsage)) {
            if (acquireFence >= 0) {
                close(acquireFence);
            }
            return AIMAPPER_ERROR_BAD_VALUE;
        }
        if (!isImported(buffer) || !validateHandle(buffer, &header)) {
            if (acquireFence >= 0) {
                close(acquireFence);
            }
            return AIMAPPER_ERROR_BAD_BUFFER;
        }
        if (!regionValid(accessRegion, header)) {
            if (acquireFence >= 0) {
                close(acquireFence);
            }
            return AIMAPPER_ERROR_BAD_VALUE;
        }
        if (acquireFence >= 0) {
            const int waitResult = sync_wait(acquireFence, -1);
            close(acquireFence);
            if (waitResult != 0) {
                return AIMAPPER_ERROR_NO_RESOURCES;
            }
        }

        std::lock_guard<std::mutex> guard(mMutex);
        auto& mapping = mMappings[buffer];
        if (mapping.base == MAP_FAILED) {
            size_t size = 0;
            if (!validateHandle(buffer, nullptr, &size)) {
                mMappings.erase(buffer);
                return AIMAPPER_ERROR_BAD_BUFFER;
            }
            mapping.base = mmap(nullptr, size, PROT_READ | PROT_WRITE, MAP_SHARED, buffer->data[0], 0);
            if (mapping.base == MAP_FAILED) {
                mMappings.erase(buffer);
                return AIMAPPER_ERROR_NO_RESOURCES;
            }
            mapping.size = size;
        }
        ++mapping.locks;
        *outData = static_cast<uint8_t*>(mapping.base) + kPixelOffset;
        return AIMAPPER_ERROR_NONE;
    }

    AIMapper_Error unlock(buffer_handle_t buffer, int* releaseFence) override {
        if (releaseFence == nullptr) {
            return AIMAPPER_ERROR_BAD_VALUE;
        }
        std::lock_guard<std::mutex> guard(mMutex);
        auto mapped = mMappings.find(buffer);
        if (mImported.find(buffer) == mImported.end() || mapped == mMappings.end() ||
            mapped->second.locks == 0) {
            return AIMAPPER_ERROR_BAD_BUFFER;
        }
        --mapped->second.locks;
        *releaseFence = -1;
        return AIMAPPER_ERROR_NONE;
    }

    AIMapper_Error flushLockedBuffer(buffer_handle_t buffer) override {
        std::lock_guard<std::mutex> guard(mMutex);
        auto mapped = mMappings.find(buffer);
        if (mImported.find(buffer) == mImported.end() || mapped == mMappings.end() ||
            mapped->second.locks == 0) {
            return AIMAPPER_ERROR_BAD_BUFFER;
        }
        return msync(mapped->second.base, mapped->second.size, MS_SYNC) == 0 ? AIMAPPER_ERROR_NONE
                                                                            : AIMAPPER_ERROR_NO_RESOURCES;
    }

    AIMapper_Error rereadLockedBuffer(buffer_handle_t buffer) override {
        std::lock_guard<std::mutex> guard(mMutex);
        auto mapped = mMappings.find(buffer);
        if (mImported.find(buffer) == mImported.end() || mapped == mMappings.end() ||
            mapped->second.locks == 0) {
            return AIMAPPER_ERROR_BAD_BUFFER;
        }
        return AIMAPPER_ERROR_NONE;
    }

    int32_t getMetadata(buffer_handle_t buffer, AIMapper_MetadataType metadataType, void* destBuffer,
                        size_t destBufferSize) override {
        if (metadataType.name == nullptr || std::string_view(metadataType.name) != kStandardMetadataName) {
            return -AIMAPPER_ERROR_UNSUPPORTED;
        }
        return getStandardMetadata(buffer, metadataType.value, destBuffer, destBufferSize);
    }

    int32_t getStandardMetadata(buffer_handle_t buffer, int64_t standardMetadataType, void* destBuffer,
                                size_t destBufferSize) override {
        RoydBufferHeader header = {};
        if (!isImported(buffer) || !validateHandle(buffer, &header)) {
            return -AIMAPPER_ERROR_BAD_BUFFER;
        }
        const auto type = static_cast<StandardMetadataType>(standardMetadataType);
        return android::hardware::graphics::mapper::provideStandardMetadata(
                type, destBuffer, destBufferSize,
                [&]<StandardMetadataType T>(auto encode) -> int32_t {
                    if constexpr (T == StandardMetadataType::BUFFER_ID) {
                        return encode(header.bufferId);
                    } else if constexpr (T == StandardMetadataType::NAME) {
                        return encode(headerName(header));
                    } else if constexpr (T == StandardMetadataType::WIDTH) {
                        return encode(static_cast<uint64_t>(header.width));
                    } else if constexpr (T == StandardMetadataType::HEIGHT) {
                        return encode(static_cast<uint64_t>(header.height));
                    } else if constexpr (T == StandardMetadataType::LAYER_COUNT) {
                        return encode(static_cast<uint64_t>(header.layerCount));
                    } else if constexpr (T == StandardMetadataType::PIXEL_FORMAT_REQUESTED) {
                        return encode(static_cast<PixelFormat>(header.format));
                    } else if constexpr (T == StandardMetadataType::PIXEL_FORMAT_FOURCC) {
                        return encode(drmFourccForFormat(static_cast<PixelFormat>(header.format)));
                    } else if constexpr (T == StandardMetadataType::PIXEL_FORMAT_MODIFIER) {
                        return encode(static_cast<uint64_t>(0));
                    } else if constexpr (T == StandardMetadataType::USAGE) {
                        return encode(static_cast<BufferUsage>(header.usage));
                    } else if constexpr (T == StandardMetadataType::ALLOCATION_SIZE) {
                        return encode(header.allocationSize);
                    } else if constexpr (T == StandardMetadataType::PROTECTED_CONTENT) {
                        return encode(static_cast<uint64_t>(0));
                    } else if constexpr (T == StandardMetadataType::COMPRESSION) {
                        return encode(extension(kCompressionName, 0));
                    } else if constexpr (T == StandardMetadataType::INTERLACED) {
                        return encode(extension(kInterlacedName, 0));
                    } else if constexpr (T == StandardMetadataType::CHROMA_SITING) {
                        return encode(extension(kChromaSitingName, 0));
                    } else if constexpr (T == StandardMetadataType::PLANE_LAYOUTS) {
                        return encode(planeLayouts(header));
                    } else if constexpr (T == StandardMetadataType::CROP) {
                        Rect crop;
                        crop.left = 0;
                        crop.top = 0;
                        crop.right = static_cast<int32_t>(header.width);
                        crop.bottom = static_cast<int32_t>(header.height);
                        return encode(std::vector<Rect>{crop});
                    } else if constexpr (T == StandardMetadataType::DATASPACE) {
                        return encode(static_cast<Dataspace>(header.dataspace));
                    } else if constexpr (T == StandardMetadataType::BLEND_MODE) {
                        return encode(static_cast<BlendMode>(header.blendMode));
                    } else if constexpr (T == StandardMetadataType::SMPTE2086) {
                        std::optional<Smpte2086> value;
                        if (header.hasSmpte2086 != 0) {
                            value = readSmpte2086(header);
                        }
                        return encode(value);
                    } else if constexpr (T == StandardMetadataType::CTA861_3) {
                        std::optional<Cta861_3> value;
                        if (header.hasCta8613 != 0) {
                            value = readCta8613(header);
                        }
                        return encode(value);
                    } else if constexpr (T == StandardMetadataType::SMPTE2094_10) {
                        std::optional<std::vector<uint8_t>> value;
                        if (header.smpte2094_10Size != 0) {
                            value = std::vector<uint8_t>(header.smpte2094_10,
                                                         header.smpte2094_10 + header.smpte2094_10Size);
                        }
                        return encode(value);
                    } else if constexpr (T == StandardMetadataType::SMPTE2094_40) {
                        std::optional<std::vector<uint8_t>> value;
                        if (header.smpte2094_40Size != 0) {
                            value = std::vector<uint8_t>(header.smpte2094_40,
                                                         header.smpte2094_40 + header.smpte2094_40Size);
                        }
                        return encode(value);
                    } else if constexpr (T == StandardMetadataType::STRIDE) {
                        return encode(header.stride);
                    } else {
                        return -AIMAPPER_ERROR_UNSUPPORTED;
                    }
                });
    }

    AIMapper_Error setMetadata(buffer_handle_t buffer, AIMapper_MetadataType metadataType,
                               const void* metadata, size_t metadataSize) override {
        if (metadataType.name == nullptr || std::string_view(metadataType.name) != kStandardMetadataName) {
            return AIMAPPER_ERROR_UNSUPPORTED;
        }
        return setStandardMetadata(buffer, metadataType.value, metadata, metadataSize);
    }

    AIMapper_Error setStandardMetadata(buffer_handle_t buffer, int64_t standardMetadataType,
                                       const void* metadata, size_t metadataSize) override {
        RoydBufferHeader header = {};
        if (!isImported(buffer) || !validateHandle(buffer, &header)) {
            return AIMAPPER_ERROR_BAD_BUFFER;
        }
        const auto type = static_cast<StandardMetadataType>(standardMetadataType);
        if (std::find(kStandardTypes.begin(), kStandardTypes.end(), type) == kStandardTypes.end()) {
            return AIMAPPER_ERROR_UNSUPPORTED;
        }
        if (!settable(type)) {
            return AIMAPPER_ERROR_BAD_VALUE;
        }
        bool changed = false;
        const AIMapper_Error result = android::hardware::graphics::mapper::applyStandardMetadata(
                type, metadata, metadataSize,
                [&]<StandardMetadataType T>(const auto& value) -> AIMapper_Error {
                    if constexpr (T == StandardMetadataType::DATASPACE) {
                        header.dataspace = static_cast<int32_t>(value);
                        changed = true;
                        return AIMAPPER_ERROR_NONE;
                    } else if constexpr (T == StandardMetadataType::BLEND_MODE) {
                        header.blendMode = static_cast<int32_t>(value);
                        changed = true;
                        return AIMAPPER_ERROR_NONE;
                    } else if constexpr (T == StandardMetadataType::SMPTE2086) {
                        header.hasSmpte2086 = value.has_value() ? 1 : 0;
                        if (value.has_value()) {
                            writeSmpte2086(&header, *value);
                        }
                        changed = true;
                        return AIMAPPER_ERROR_NONE;
                    } else if constexpr (T == StandardMetadataType::CTA861_3) {
                        header.hasCta8613 = value.has_value() ? 1 : 0;
                        if (value.has_value()) {
                            writeCta8613(&header, *value);
                        }
                        changed = true;
                        return AIMAPPER_ERROR_NONE;
                    } else if constexpr (T == StandardMetadataType::SMPTE2094_10) {
                        if (value.has_value() && value->size() > kDynamicHdrMetadataCapacity) {
                            return AIMAPPER_ERROR_NO_RESOURCES;
                        }
                        header.smpte2094_10Size = value.has_value() ? value->size() : 0;
                        if (value.has_value()) {
                            std::copy(value->begin(), value->end(), header.smpte2094_10);
                        }
                        changed = true;
                        return AIMAPPER_ERROR_NONE;
                    } else if constexpr (T == StandardMetadataType::SMPTE2094_40) {
                        if (value.has_value() && value->size() > kDynamicHdrMetadataCapacity) {
                            return AIMAPPER_ERROR_NO_RESOURCES;
                        }
                        header.smpte2094_40Size = value.has_value() ? value->size() : 0;
                        if (value.has_value()) {
                            std::copy(value->begin(), value->end(), header.smpte2094_40);
                        }
                        changed = true;
                        return AIMAPPER_ERROR_NONE;
                    } else {
                        return AIMAPPER_ERROR_UNSUPPORTED;
                    }
                });
        if (result != AIMAPPER_ERROR_NONE || !changed) {
            return result;
        }
        return writeHeader(buffer, header) ? AIMAPPER_ERROR_NONE : AIMAPPER_ERROR_NO_RESOURCES;
    }

    AIMapper_Error listSupportedMetadataTypes(const AIMapper_MetadataTypeDescription** outDescriptionList,
                                              size_t* outNumberOfDescriptions) override {
        if (outDescriptionList == nullptr || outNumberOfDescriptions == nullptr) {
            return AIMAPPER_ERROR_BAD_VALUE;
        }
        static const auto descriptions = makeDescriptions();
        *outDescriptionList = descriptions.data();
        *outNumberOfDescriptions = descriptions.size();
        return AIMAPPER_ERROR_NONE;
    }

    AIMapper_Error dumpBuffer(buffer_handle_t buffer, AIMapper_DumpBufferCallback callback,
                              void* context) override {
        if (callback == nullptr || !isImported(buffer)) {
            return AIMAPPER_ERROR_BAD_BUFFER;
        }
        for (const auto type : kStandardTypes) {
            const int32_t size = getStandardMetadata(buffer, static_cast<int64_t>(type), nullptr, 0);
            if (size < 0) {
                continue;
            }
            std::vector<uint8_t> data(static_cast<size_t>(size));
            const int32_t written = getStandardMetadata(buffer, static_cast<int64_t>(type), data.data(), data.size());
            if (written < 0) {
                return AIMAPPER_ERROR_NO_RESOURCES;
            }
            const uint8_t empty = 0;
            const void* value = written == 0 ? static_cast<const void*>(&empty) : data.data();
            callback(context, AIMapper_MetadataType{kStandardMetadataName, static_cast<int64_t>(type)},
                     value, static_cast<size_t>(written));
        }
        return AIMAPPER_ERROR_NONE;
    }

    AIMapper_Error dumpAllBuffers(AIMapper_BeginDumpBufferCallback beginCallback,
                                  AIMapper_DumpBufferCallback dumpCallback, void* context) override {
        if (beginCallback == nullptr || dumpCallback == nullptr) {
            return AIMAPPER_ERROR_BAD_VALUE;
        }
        std::vector<buffer_handle_t> buffers;
        {
            std::lock_guard<std::mutex> guard(mMutex);
            buffers.assign(mImported.begin(), mImported.end());
        }
        for (const auto buffer : buffers) {
            beginCallback(context);
            const auto result = dumpBuffer(buffer, dumpCallback, context);
            if (result != AIMAPPER_ERROR_NONE) {
                return result;
            }
        }
        return AIMAPPER_ERROR_NONE;
    }

    AIMapper_Error getReservedRegion(buffer_handle_t buffer, void** outReservedRegion,
                                     uint64_t* outReservedSize) override {
        RoydBufferHeader header = {};
        if (outReservedRegion == nullptr || outReservedSize == nullptr || !isImported(buffer) ||
            !validateHandle(buffer, &header)) {
            return AIMAPPER_ERROR_BAD_BUFFER;
        }
        if (header.reservedSize == 0) {
            *outReservedRegion = nullptr;
            *outReservedSize = 0;
            return AIMAPPER_ERROR_NONE;
        }

        std::lock_guard<std::mutex> guard(mMutex);
        auto& mapping = mMappings[buffer];
        if (mapping.base == MAP_FAILED) {
            size_t size = 0;
            if (!validateHandle(buffer, nullptr, &size)) {
                mMappings.erase(buffer);
                return AIMAPPER_ERROR_BAD_BUFFER;
            }
            mapping.base = mmap(nullptr, size, PROT_READ | PROT_WRITE, MAP_SHARED, buffer->data[0], 0);
            if (mapping.base == MAP_FAILED) {
                mMappings.erase(buffer);
                return AIMAPPER_ERROR_NO_RESOURCES;
            }
            mapping.size = size;
        }
        *outReservedRegion = static_cast<uint8_t*>(mapping.base) + header.reservedOffset;
        *outReservedSize = header.reservedSize;
        return AIMAPPER_ERROR_NONE;
    }

  private:
    bool isImported(buffer_handle_t buffer) {
        std::lock_guard<std::mutex> guard(mMutex);
        return mImported.find(buffer) != mImported.end();
    }

    std::mutex mMutex;
    std::set<buffer_handle_t> mImported;
    std::unordered_map<buffer_handle_t, Mapping> mMappings;
};

}  // namespace royd::graphics

extern "C" uint32_t ANDROID_HAL_STABLEC_VERSION = AIMAPPER_VERSION_5;
extern "C" uint32_t ANDROID_HAL_MAPPER_VERSION = AIMAPPER_VERSION_5;

extern "C" AIMapper_Error AIMapper_loadIMapper(AIMapper** outImplementation) {
    static vendor::mapper::IMapperProvider<royd::graphics::Mapper> provider;
    return provider.load(outImplementation);
}
