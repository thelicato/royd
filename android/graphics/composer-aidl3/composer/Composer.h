#pragma once

#include <aidl/android/hardware/common/NativeHandle.h>
#include <aidl/android/hardware/graphics/common/DisplayDecorationSupport.h>
#include <aidl/android/hardware/graphics/common/Hdr.h>
#include <aidl/android/hardware/graphics/common/HdrConversionCapability.h>
#include <aidl/android/hardware/graphics/common/HdrConversionStrategy.h>
#include <aidl/android/hardware/graphics/common/PixelFormat.h>
#include <aidl/android/hardware/graphics/composer3/BnComposer.h>
#include <aidl/android/hardware/graphics/composer3/BnComposerClient.h>
#include <aidl/android/hardware/graphics/composer3/IComposerCallback.h>

#include <atomic>
#include <cstdint>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

namespace royd::graphics::composer {

namespace c3 = aidl::android::hardware::graphics::composer3;
namespace common = aidl::android::hardware::graphics::common;

class ComposerClient final : public c3::BnComposerClient {
  public:
    ComposerClient();
    ~ComposerClient() override;

    ndk::ScopedAStatus createLayer(int64_t display, int32_t bufferSlotCount, int64_t* layer) override;
    ndk::ScopedAStatus createVirtualDisplay(int32_t width, int32_t height,
                                            common::PixelFormat formatHint,
                                            int32_t outputBufferSlotCount,
                                            c3::VirtualDisplay* display) override;
    ndk::ScopedAStatus destroyLayer(int64_t display, int64_t layer) override;
    ndk::ScopedAStatus destroyVirtualDisplay(int64_t display) override;
    ndk::ScopedAStatus executeCommands(const std::vector<c3::DisplayCommand>& commands,
                                       std::vector<c3::CommandResultPayload>* results) override;
    ndk::ScopedAStatus getActiveConfig(int64_t display, int32_t* config) override;
    ndk::ScopedAStatus getColorModes(int64_t display, std::vector<c3::ColorMode>* colorModes) override;
    ndk::ScopedAStatus getDataspaceSaturationMatrix(common::Dataspace dataspace,
                                                     std::vector<float>* matrix) override;
    ndk::ScopedAStatus getDisplayAttribute(int64_t display, int32_t config,
                                           c3::DisplayAttribute attribute, int32_t* value) override;
    ndk::ScopedAStatus getDisplayCapabilities(int64_t display,
                                              std::vector<c3::DisplayCapability>* caps) override;
    ndk::ScopedAStatus getDisplayConfigs(int64_t display, std::vector<int32_t>* configs) override;
    ndk::ScopedAStatus getDisplayConnectionType(int64_t display,
                                                 c3::DisplayConnectionType* type) override;
    ndk::ScopedAStatus getDisplayIdentificationData(int64_t display,
                                                    c3::DisplayIdentification* id) override;
    ndk::ScopedAStatus getDisplayName(int64_t display, std::string* name) override;
    ndk::ScopedAStatus getDisplayVsyncPeriod(int64_t display, int32_t* vsyncPeriod) override;
    ndk::ScopedAStatus getDisplayedContentSample(int64_t display, int64_t maxFrames,
                                                 int64_t timestamp,
                                                 c3::DisplayContentSample* samples) override;
    ndk::ScopedAStatus getDisplayedContentSamplingAttributes(
            int64_t display, c3::DisplayContentSamplingAttributes* attrs) override;
    ndk::ScopedAStatus getDisplayPhysicalOrientation(int64_t display,
                                                     common::Transform* orientation) override;
    ndk::ScopedAStatus getHdrCapabilities(int64_t display, c3::HdrCapabilities* caps) override;
    ndk::ScopedAStatus getOverlaySupport(c3::OverlayProperties* caps) override;
    ndk::ScopedAStatus getMaxVirtualDisplayCount(int32_t* count) override;
    ndk::ScopedAStatus getPerFrameMetadataKeys(int64_t display,
                                               std::vector<c3::PerFrameMetadataKey>* keys) override;
    ndk::ScopedAStatus getReadbackBufferAttributes(int64_t display,
                                                   c3::ReadbackBufferAttributes* attrs) override;
    ndk::ScopedAStatus getReadbackBufferFence(int64_t display,
                                              ndk::ScopedFileDescriptor* acquireFence) override;
    ndk::ScopedAStatus getRenderIntents(int64_t display, c3::ColorMode mode,
                                        std::vector<c3::RenderIntent>* intents) override;
    ndk::ScopedAStatus getSupportedContentTypes(int64_t display,
                                                std::vector<c3::ContentType>* types) override;
    ndk::ScopedAStatus getDisplayDecorationSupport(
            int64_t display, std::optional<common::DisplayDecorationSupport>* support) override;
    ndk::ScopedAStatus registerCallback(const std::shared_ptr<c3::IComposerCallback>& callback) override;
    ndk::ScopedAStatus setActiveConfig(int64_t display, int32_t config) override;
    ndk::ScopedAStatus setActiveConfigWithConstraints(
            int64_t display, int32_t config, const c3::VsyncPeriodChangeConstraints& constraints,
            c3::VsyncPeriodChangeTimeline* timeline) override;
    ndk::ScopedAStatus setBootDisplayConfig(int64_t display, int32_t config) override;
    ndk::ScopedAStatus clearBootDisplayConfig(int64_t display) override;
    ndk::ScopedAStatus getPreferredBootDisplayConfig(int64_t display, int32_t* config) override;
    ndk::ScopedAStatus getHdrConversionCapabilities(
            std::vector<common::HdrConversionCapability>* capabilities) override;
    ndk::ScopedAStatus setHdrConversionStrategy(const common::HdrConversionStrategy& strategy,
                                                common::Hdr* preferredHdrOutputType) override;
    ndk::ScopedAStatus setAutoLowLatencyMode(int64_t display, bool on) override;
    ndk::ScopedAStatus setClientTargetSlotCount(int64_t display, int32_t count) override;
    ndk::ScopedAStatus setColorMode(int64_t display, c3::ColorMode mode,
                                    c3::RenderIntent intent) override;
    ndk::ScopedAStatus setContentType(int64_t display, c3::ContentType type) override;
    ndk::ScopedAStatus setDisplayedContentSamplingEnabled(int64_t display, bool enable,
                                                          c3::FormatColorComponent componentMask,
                                                          int64_t maxFrames) override;
    ndk::ScopedAStatus setPowerMode(int64_t display, c3::PowerMode mode) override;
    ndk::ScopedAStatus setReadbackBuffer(int64_t display,
                                         const aidl::android::hardware::common::NativeHandle& buffer,
                                         const ndk::ScopedFileDescriptor& releaseFence) override;
    ndk::ScopedAStatus setVsyncEnabled(int64_t display, bool enabled) override;
    ndk::ScopedAStatus setIdleTimerEnabled(int64_t display, int32_t timeout) override;
    ndk::ScopedAStatus setRefreshRateChangedCallbackDebugEnabled(int64_t display,
                                                                 bool enabled) override;
    ndk::ScopedAStatus getDisplayConfigurations(
            int64_t display, int32_t maxFrameIntervalNs,
            std::vector<c3::DisplayConfiguration>* configs) override;
    ndk::ScopedAStatus notifyExpectedPresent(int64_t display,
                                             const c3::ClockMonotonicTimestamp& expectedPresentTime,
                                             int32_t frameIntervalNs) override;

  private:
    static constexpr int64_t kDisplayId = 1;
    static constexpr int32_t kConfigId = 0;

    bool isDisplay(int64_t display) const;
    ndk::ScopedAStatus badDisplay() const;
    ndk::ScopedAStatus badConfig() const;
    ndk::ScopedAStatus unsupported() const;
    int64_t nowNanos() const;
    ndk::ScopedFileDescriptor makeSignalledFence() const;
    void vsyncLoop();

    int32_t mWidth;
    int32_t mHeight;
    int32_t mDpi;
    int32_t mVsyncPeriodNs;
    int64_t mNextLayer = 1;
    std::unordered_map<int64_t, c3::Composition> mLayers;
    std::vector<int64_t> mPendingClientLayers;
    bool mValidated = false;

    std::mutex mMutex;
    std::shared_ptr<c3::IComposerCallback> mCallback;
    std::atomic<bool> mVsyncEnabled{false};
    std::atomic<bool> mStopVsync{false};
    std::thread mVsyncThread;
};

class Composer final : public c3::BnComposer {
  public:
    ndk::ScopedAStatus createClient(std::shared_ptr<c3::IComposerClient>* client) override;
    ndk::ScopedAStatus getCapabilities(std::vector<c3::Capability>* capabilities) override;

  private:
    std::mutex mMutex;
    std::weak_ptr<ComposerClient> mClient;
};

}  // namespace royd::graphics::composer
