#pragma once

#include <cstdint>

namespace royd::graphics {

constexpr int kHandleFds = 1;
constexpr int kHandleInts = 2;
constexpr int32_t kHandleMagic = 0x524f5944;
constexpr int32_t kHandleVersion = 1;
constexpr uint32_t kHeaderMagic = 0x524f5944u;
constexpr uint32_t kHeaderVersion = 1;
constexpr uint64_t kPixelOffset = 4096;
constexpr uint32_t kDynamicHdrMetadataCapacity = 1024;

struct RoydBufferHeader {
    uint32_t magic;
    uint32_t version;
    uint64_t bufferId;
    uint64_t usage;
    uint64_t allocationSize;
    uint64_t pixelSize;
    uint64_t reservedSize;
    uint64_t reservedOffset;
    uint32_t width;
    uint32_t height;
    uint32_t layerCount;
    int32_t format;
    uint32_t stride;
    uint32_t bytesPerPixel;
    int32_t dataspace;
    int32_t blendMode;
    uint32_t hasSmpte2086;
    uint32_t hasCta8613;
    float smpte2086[10];
    float cta8613[2];
    uint32_t smpte2094_10Size;
    uint32_t smpte2094_40Size;
    uint8_t smpte2094_10[kDynamicHdrMetadataCapacity];
    uint8_t smpte2094_40[kDynamicHdrMetadataCapacity];
    char name[128];
};

static_assert(sizeof(RoydBufferHeader) <= kPixelOffset);

}  // namespace royd::graphics
