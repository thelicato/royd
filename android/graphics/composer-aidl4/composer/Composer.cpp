#include "Composer.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wsign-compare"
#include <android/hardware/graphics/composer3/ComposerServiceWriter.h>
#pragma clang diagnostic pop
#include <cutils/properties.h>
#include <log/log.h>
#include <sys/eventfd.h>

#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <limits>
#include <thread>

namespace royd::graphics::composer {
namespace {

int32_t propertyInt(const char* name, int32_t fallback) {
    char value[PROPERTY_VALUE_MAX] = {};
    if (property_get(name, value, "") <= 0) return fallback;

    char* end = nullptr;
    const long parsed = std::strtol(value, &end, 10);
    if (end == value || *end != '\0' || parsed <= 0 || parsed > std::numeric_limits<int32_t>::max()) {
        ALOGW("ignoring invalid %s=%s", name, value);
        return fallback;
    }
    return static_cast<int32_t>(parsed);
}

ndk::ScopedAStatus serviceError(int32_t error) {
    return ndk::ScopedAStatus::fromServiceSpecificError(error);
}

}  // namespace

ComposerClient::ComposerClient()
    : mWidth(propertyInt("vendor.royd.display.width", 540)),
      mHeight(propertyInt("vendor.royd.display.height", 960)),
      mDpi(propertyInt("vendor.royd.display.dpi", 240)) {
    const int32_t fps = propertyInt("vendor.royd.display.fps", 30);
    mVsyncPeriodNs = static_cast<int32_t>(1000000000LL / fps);
    mVsyncThread = std::thread(&ComposerClient::vsyncLoop, this);
}

ComposerClient::~ComposerClient() {
    mStopVsync.store(true);
    if (mVsyncThread.joinable()) mVsyncThread.join();
}

bool ComposerClient::isDisplay(int64_t display) const {
    return display == kDisplayId;
}

ndk::ScopedAStatus ComposerClient::badDisplay() const {
    return serviceError(c3::IComposerClient::EX_BAD_DISPLAY);
}

ndk::ScopedAStatus ComposerClient::badConfig() const {
    return serviceError(c3::IComposerClient::EX_BAD_CONFIG);
}

ndk::ScopedAStatus ComposerClient::unsupported() const {
    return serviceError(c3::IComposerClient::EX_UNSUPPORTED);
}

int64_t ComposerClient::nowNanos() const {
    return std::chrono::duration_cast<std::chrono::nanoseconds>(
                   std::chrono::steady_clock::now().time_since_epoch())
            .count();
}

ndk::ScopedFileDescriptor ComposerClient::makeSignalledFence() const {
    return ndk::ScopedFileDescriptor(eventfd(1, EFD_CLOEXEC | EFD_NONBLOCK));
}

ndk::ScopedAStatus ComposerClient::createLayer(int64_t display, int32_t bufferSlotCount,
                                                int64_t* layer) {
    if (!isDisplay(display)) return badDisplay();
    if (bufferSlotCount <= 0) return serviceError(c3::IComposerClient::EX_BAD_PARAMETER);

    std::lock_guard lock(mMutex);
    *layer = mNextLayer++;
    mLayers[*layer] = c3::Composition::CLIENT;
    mValidated = false;
    return ndk::ScopedAStatus::ok();
}

ndk::ScopedAStatus ComposerClient::createVirtualDisplay(int32_t /*width*/, int32_t /*height*/,
                                                         common::PixelFormat /*formatHint*/,
                                                         int32_t /*outputBufferSlotCount*/,
                                                         c3::VirtualDisplay* /*display*/) {
    return unsupported();
}

ndk::ScopedAStatus ComposerClient::destroyLayer(int64_t display, int64_t layer) {
    if (!isDisplay(display)) return badDisplay();

    std::lock_guard lock(mMutex);
    if (mLayers.erase(layer) == 0) return serviceError(c3::IComposerClient::EX_BAD_LAYER);
    mPendingClientLayers.erase(
            std::remove(mPendingClientLayers.begin(), mPendingClientLayers.end(), layer),
            mPendingClientLayers.end());
    mValidated = false;
    return ndk::ScopedAStatus::ok();
}

ndk::ScopedAStatus ComposerClient::destroyVirtualDisplay(int64_t /*display*/) {
    return unsupported();
}

ndk::ScopedAStatus ComposerClient::executeCommands(
        const std::vector<c3::DisplayCommand>& commands,
        std::vector<c3::CommandResultPayload>* results) {
    c3::impl::ComposerServiceWriter writer;

    std::lock_guard lock(mMutex);
    for (size_t commandIndex = 0; commandIndex < commands.size(); ++commandIndex) {
        const auto& command = commands[commandIndex];
        if (!isDisplay(command.display)) {
            writer.setError(static_cast<int32_t>(commandIndex), c3::IComposerClient::EX_BAD_DISPLAY);
            continue;
        }

        bool commandError = false;
        for (const auto& layerCommand : command.layers) {
            auto layer = mLayers.find(layerCommand.layer);
            if (layer == mLayers.end()) {
                writer.setError(static_cast<int32_t>(commandIndex), c3::IComposerClient::EX_BAD_LAYER);
                commandError = true;
                break;
            }
            if (layerCommand.composition.has_value()) {
                layer->second = layerCommand.composition->composition;
                mValidated = false;
            }
        }
        if (commandError) continue;

        // BRIGHTNESS is not advertised. Android's composer3 VTS requires an
        // explicit command error when a client probes unsupported brightness.
        if (command.brightness.has_value()) {
            writer.setError(static_cast<int32_t>(commandIndex),
                            c3::IComposerClient::EX_UNSUPPORTED);
            continue;
        }

        if (command.acceptDisplayChanges) {
            for (const int64_t layer : mPendingClientLayers) {
                auto found = mLayers.find(layer);
                if (found != mLayers.end()) found->second = c3::Composition::CLIENT;
            }
            mPendingClientLayers.clear();
        }

        auto validate = [&] {
            std::vector<int64_t> changedLayers;
            std::vector<c3::Composition> changedTypes;
            mPendingClientLayers.clear();
            for (const auto& [layer, composition] : mLayers) {
                if (composition == c3::Composition::CLIENT) continue;
                changedLayers.push_back(layer);
                changedTypes.push_back(c3::Composition::CLIENT);
                mPendingClientLayers.push_back(layer);
            }
            if (!changedLayers.empty()) {
                writer.setChangedCompositionTypes(command.display, changedLayers, changedTypes);
            }
            mValidated = true;
        };

        if (command.validateDisplay) validate();

        if (command.presentOrValidateDisplay) {
            if (!mValidated || !mPendingClientLayers.empty()) {
                validate();
                writer.setPresentOrValidateResult(command.display,
                                                   c3::PresentOrValidate::Result::Validated);
            } else {
                writer.setPresentFence(command.display, makeSignalledFence());
                writer.setReleaseFences(command.display, {}, {});
                writer.setPresentOrValidateResult(command.display,
                                                   c3::PresentOrValidate::Result::Presented);
                mValidated = false;
            }
        }

        if (command.presentDisplay) {
            if (!mValidated || !mPendingClientLayers.empty()) {
                writer.setError(static_cast<int32_t>(commandIndex),
                                c3::IComposerClient::EX_NOT_VALIDATED);
                continue;
            }
            writer.setPresentFence(command.display, makeSignalledFence());
            writer.setReleaseFences(command.display, {}, {});
            mValidated = false;
        }
    }

    *results = writer.getPendingCommandResults();
    return ndk::ScopedAStatus::ok();
}

ndk::ScopedAStatus ComposerClient::getActiveConfig(int64_t display, int32_t* config) {
    if (!isDisplay(display)) return badDisplay();
    *config = kConfigId;
    return ndk::ScopedAStatus::ok();
}

ndk::ScopedAStatus ComposerClient::getColorModes(int64_t display,
                                                  std::vector<c3::ColorMode>* colorModes) {
    if (!isDisplay(display)) return badDisplay();
    *colorModes = {c3::ColorMode::NATIVE};
    return ndk::ScopedAStatus::ok();
}

ndk::ScopedAStatus ComposerClient::getDataspaceSaturationMatrix(common::Dataspace dataspace,
                                                                 std::vector<float>* matrix) {
    if (dataspace != common::Dataspace::SRGB_LINEAR) {
        return serviceError(c3::IComposerClient::EX_BAD_PARAMETER);
    }
    *matrix = {1.0f, 0.0f, 0.0f, 0.0f,
               0.0f, 1.0f, 0.0f, 0.0f,
               0.0f, 0.0f, 1.0f, 0.0f,
               0.0f, 0.0f, 0.0f, 1.0f};
    return ndk::ScopedAStatus::ok();
}

ndk::ScopedAStatus ComposerClient::getDisplayAttribute(int64_t display, int32_t config,
                                                        c3::DisplayAttribute attribute,
                                                        int32_t* value) {
    if (!isDisplay(display)) return badDisplay();
    if (config != kConfigId) return badConfig();

    switch (attribute) {
        case c3::DisplayAttribute::WIDTH:
            *value = mWidth;
            break;
        case c3::DisplayAttribute::HEIGHT:
            *value = mHeight;
            break;
        case c3::DisplayAttribute::VSYNC_PERIOD:
            *value = mVsyncPeriodNs;
            break;
        case c3::DisplayAttribute::DPI_X:
        case c3::DisplayAttribute::DPI_Y:
            *value = mDpi * 1000;
            break;
        case c3::DisplayAttribute::CONFIG_GROUP:
            *value = 0;
            break;
        default:
            return serviceError(c3::IComposerClient::EX_BAD_PARAMETER);
    }
    return ndk::ScopedAStatus::ok();
}

ndk::ScopedAStatus ComposerClient::getDisplayCapabilities(
        int64_t display, std::vector<c3::DisplayCapability>* caps) {
    if (!isDisplay(display)) return badDisplay();
    caps->clear();
    return ndk::ScopedAStatus::ok();
}

ndk::ScopedAStatus ComposerClient::getDisplayConfigs(int64_t display,
                                                      std::vector<int32_t>* configs) {
    if (!isDisplay(display)) return badDisplay();
    *configs = {kConfigId};
    return ndk::ScopedAStatus::ok();
}

ndk::ScopedAStatus ComposerClient::getDisplayConnectionType(int64_t display,
                                                             c3::DisplayConnectionType* type) {
    if (!isDisplay(display)) return badDisplay();
    *type = c3::DisplayConnectionType::INTERNAL;
    return ndk::ScopedAStatus::ok();
}

ndk::ScopedAStatus ComposerClient::getDisplayIdentificationData(
        int64_t display, c3::DisplayIdentification* /*id*/) {
    if (!isDisplay(display)) return badDisplay();
    return unsupported();
}

ndk::ScopedAStatus ComposerClient::getDisplayName(int64_t display, std::string* name) {
    if (!isDisplay(display)) return badDisplay();
    *name = "royd client-composition display";
    return ndk::ScopedAStatus::ok();
}

ndk::ScopedAStatus ComposerClient::getDisplayVsyncPeriod(int64_t display, int32_t* vsyncPeriod) {
    if (!isDisplay(display)) return badDisplay();
    *vsyncPeriod = mVsyncPeriodNs;
    return ndk::ScopedAStatus::ok();
}

ndk::ScopedAStatus ComposerClient::getDisplayedContentSample(
        int64_t display, int64_t /*maxFrames*/, int64_t /*timestamp*/,
        c3::DisplayContentSample* /*samples*/) {
    if (!isDisplay(display)) return badDisplay();
    return unsupported();
}

ndk::ScopedAStatus ComposerClient::getDisplayedContentSamplingAttributes(
        int64_t display, c3::DisplayContentSamplingAttributes* /*attrs*/) {
    if (!isDisplay(display)) return badDisplay();
    return unsupported();
}

ndk::ScopedAStatus ComposerClient::getDisplayPhysicalOrientation(int64_t display,
                                                                  common::Transform* orientation) {
    if (!isDisplay(display)) return badDisplay();
    *orientation = static_cast<common::Transform>(0);
    return ndk::ScopedAStatus::ok();
}

ndk::ScopedAStatus ComposerClient::getHdrCapabilities(int64_t display, c3::HdrCapabilities* caps) {
    if (!isDisplay(display)) return badDisplay();
    *caps = {};
    return ndk::ScopedAStatus::ok();
}

ndk::ScopedAStatus ComposerClient::getOverlaySupport(c3::OverlayProperties* /*caps*/) {
    return unsupported();
}

ndk::ScopedAStatus ComposerClient::getMaxVirtualDisplayCount(int32_t* count) {
    *count = 0;
    return ndk::ScopedAStatus::ok();
}

ndk::ScopedAStatus ComposerClient::getPerFrameMetadataKeys(
        int64_t display, std::vector<c3::PerFrameMetadataKey>* keys) {
    if (!isDisplay(display)) return badDisplay();
    keys->clear();
    return ndk::ScopedAStatus::ok();
}

ndk::ScopedAStatus ComposerClient::getReadbackBufferAttributes(
        int64_t display, c3::ReadbackBufferAttributes* /*attrs*/) {
    if (!isDisplay(display)) return badDisplay();
    return unsupported();
}

ndk::ScopedAStatus ComposerClient::getReadbackBufferFence(
        int64_t display, ndk::ScopedFileDescriptor* /*acquireFence*/) {
    if (!isDisplay(display)) return badDisplay();
    return unsupported();
}

ndk::ScopedAStatus ComposerClient::getRenderIntents(int64_t display, c3::ColorMode mode,
                                                     std::vector<c3::RenderIntent>* intents) {
    if (!isDisplay(display)) return badDisplay();
    if (mode != c3::ColorMode::NATIVE) return serviceError(c3::IComposerClient::EX_BAD_PARAMETER);
    *intents = {c3::RenderIntent::COLORIMETRIC};
    return ndk::ScopedAStatus::ok();
}

ndk::ScopedAStatus ComposerClient::getSupportedContentTypes(int64_t display,
                                                             std::vector<c3::ContentType>* types) {
    if (!isDisplay(display)) return badDisplay();
    types->clear();
    return ndk::ScopedAStatus::ok();
}

ndk::ScopedAStatus ComposerClient::getDisplayDecorationSupport(
        int64_t display, std::optional<common::DisplayDecorationSupport>* support) {
    if (!isDisplay(display)) return badDisplay();
    support->reset();
    return ndk::ScopedAStatus::ok();
}

ndk::ScopedAStatus ComposerClient::registerCallback(
        const std::shared_ptr<c3::IComposerCallback>& callback) {
    if (!callback) return serviceError(c3::IComposerClient::EX_BAD_PARAMETER);
    {
        std::lock_guard lock(mMutex);
        mCallback = callback;
    }
    const auto status = callback->onHotplug(kDisplayId, true);
    if (!status.isOk()) ALOGW("initial display hotplug callback failed: %s", status.getDescription().c_str());
    return ndk::ScopedAStatus::ok();
}

ndk::ScopedAStatus ComposerClient::setActiveConfig(int64_t display, int32_t config) {
    if (!isDisplay(display)) return badDisplay();
    if (config != kConfigId) return badConfig();
    return ndk::ScopedAStatus::ok();
}

ndk::ScopedAStatus ComposerClient::setActiveConfigWithConstraints(
        int64_t display, int32_t config, const c3::VsyncPeriodChangeConstraints& constraints,
        c3::VsyncPeriodChangeTimeline* timeline) {
    if (!isDisplay(display)) return badDisplay();
    if (config != kConfigId) return badConfig();
    timeline->newVsyncAppliedTimeNanos = std::max(nowNanos(), constraints.desiredTimeNanos);
    timeline->refreshRequired = false;
    timeline->refreshTimeNanos = timeline->newVsyncAppliedTimeNanos;
    return ndk::ScopedAStatus::ok();
}

ndk::ScopedAStatus ComposerClient::setBootDisplayConfig(int64_t display, int32_t /*config*/) {
    if (!isDisplay(display)) return badDisplay();
    return unsupported();
}

ndk::ScopedAStatus ComposerClient::clearBootDisplayConfig(int64_t display) {
    if (!isDisplay(display)) return badDisplay();
    return unsupported();
}

ndk::ScopedAStatus ComposerClient::getPreferredBootDisplayConfig(int64_t display,
                                                                  int32_t* /*config*/) {
    if (!isDisplay(display)) return badDisplay();
    return unsupported();
}

ndk::ScopedAStatus ComposerClient::getHdrConversionCapabilities(
        std::vector<common::HdrConversionCapability>* /*capabilities*/) {
    return unsupported();
}

ndk::ScopedAStatus ComposerClient::setHdrConversionStrategy(
        const common::HdrConversionStrategy& /*strategy*/, common::Hdr* /*preferredHdrOutputType*/) {
    return unsupported();
}

ndk::ScopedAStatus ComposerClient::setAutoLowLatencyMode(int64_t display, bool /*on*/) {
    if (!isDisplay(display)) return badDisplay();
    return unsupported();
}

ndk::ScopedAStatus ComposerClient::setClientTargetSlotCount(int64_t display, int32_t count) {
    if (!isDisplay(display)) return badDisplay();
    if (count <= 0) return serviceError(c3::IComposerClient::EX_BAD_PARAMETER);
    return ndk::ScopedAStatus::ok();
}

ndk::ScopedAStatus ComposerClient::setColorMode(int64_t display, c3::ColorMode mode,
                                                 c3::RenderIntent intent) {
    if (!isDisplay(display)) return badDisplay();
    if (mode != c3::ColorMode::NATIVE || intent != c3::RenderIntent::COLORIMETRIC) {
        return serviceError(c3::IComposerClient::EX_BAD_PARAMETER);
    }
    return ndk::ScopedAStatus::ok();
}

ndk::ScopedAStatus ComposerClient::setContentType(int64_t display, c3::ContentType type) {
    if (!isDisplay(display)) return badDisplay();
    if (type != c3::ContentType::NONE) return unsupported();
    return ndk::ScopedAStatus::ok();
}

ndk::ScopedAStatus ComposerClient::setDisplayedContentSamplingEnabled(
        int64_t display, bool /*enable*/, c3::FormatColorComponent /*componentMask*/,
        int64_t /*maxFrames*/) {
    if (!isDisplay(display)) return badDisplay();
    return unsupported();
}

ndk::ScopedAStatus ComposerClient::setPowerMode(int64_t display, c3::PowerMode mode) {
    if (!isDisplay(display)) return badDisplay();
    switch (mode) {
        case c3::PowerMode::OFF:
        case c3::PowerMode::ON:
            return ndk::ScopedAStatus::ok();
        case c3::PowerMode::DOZE:
        case c3::PowerMode::DOZE_SUSPEND:
        case c3::PowerMode::ON_SUSPEND:
            return unsupported();
    }
    return serviceError(c3::IComposerClient::EX_BAD_PARAMETER);
}

ndk::ScopedAStatus ComposerClient::setReadbackBuffer(
        int64_t display, const aidl::android::hardware::common::NativeHandle& /*buffer*/,
        const ndk::ScopedFileDescriptor& /*releaseFence*/) {
    if (!isDisplay(display)) return badDisplay();
    return unsupported();
}

ndk::ScopedAStatus ComposerClient::setVsyncEnabled(int64_t display, bool enabled) {
    if (!isDisplay(display)) return badDisplay();
    mVsyncEnabled.store(enabled);
    return ndk::ScopedAStatus::ok();
}

ndk::ScopedAStatus ComposerClient::setIdleTimerEnabled(int64_t display, int32_t /*timeout*/) {
    if (!isDisplay(display)) return badDisplay();
    return unsupported();
}

ndk::ScopedAStatus ComposerClient::setRefreshRateChangedCallbackDebugEnabled(
        int64_t display, bool /*enabled*/) {
    if (!isDisplay(display)) return badDisplay();
    // This fixed-rate implementation never emits refresh-rate-change debug
    // callbacks, so enabling the callback is a harmless no-op.
    return ndk::ScopedAStatus::ok();
}

ndk::ScopedAStatus ComposerClient::getDisplayConfigurations(
        int64_t display, int32_t /*maxFrameIntervalNs*/,
        std::vector<c3::DisplayConfiguration>* configs) {
    if (!isDisplay(display)) return badDisplay();
    c3::DisplayConfiguration config;
    config.configId = kConfigId;
    config.width = mWidth;
    config.height = mHeight;
    c3::DisplayConfiguration::Dpi dpi;
    dpi.x = static_cast<float>(mDpi);
    dpi.y = static_cast<float>(mDpi);
    config.dpi = dpi;
    config.configGroup = 0;
    config.vsyncPeriod = mVsyncPeriodNs;
    configs->assign(1, config);
    return ndk::ScopedAStatus::ok();
}

ndk::ScopedAStatus ComposerClient::notifyExpectedPresent(
        int64_t display, const c3::ClockMonotonicTimestamp& /*expectedPresentTime*/,
        int32_t /*frameIntervalNs*/) {
    if (!isDisplay(display)) return badDisplay();
    return ndk::ScopedAStatus::ok();
}

ndk::ScopedAStatus ComposerClient::getMaxLayerPictureProfiles(int64_t display,
                                                               int32_t* /*maxProfiles*/) {
    if (!isDisplay(display)) return badDisplay();
    return unsupported();
}

ndk::ScopedAStatus ComposerClient::startHdcpNegotiation(
        int64_t display, const drm::HdcpLevels& /*levels*/) {
    if (!isDisplay(display)) return badDisplay();
    return unsupported();
}

ndk::ScopedAStatus ComposerClient::getLuts(int64_t display,
                                            const std::vector<c3::Buffer>& /*buffers*/,
                                            std::vector<c3::Luts>* /*luts*/) {
    if (!isDisplay(display)) return badDisplay();
    return unsupported();
}

void ComposerClient::vsyncLoop() {
    while (!mStopVsync.load()) {
        if (!mVsyncEnabled.load()) {
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
            continue;
        }

        std::this_thread::sleep_for(std::chrono::nanoseconds(mVsyncPeriodNs));
        std::shared_ptr<c3::IComposerCallback> callback;
        {
            std::lock_guard lock(mMutex);
            callback = mCallback;
        }
        if (callback && mVsyncEnabled.load() && !mStopVsync.load()) {
            const auto status = callback->onVsync(kDisplayId, nowNanos(), mVsyncPeriodNs);
            if (!status.isOk()) ALOGW("vsync callback failed: %s", status.getDescription().c_str());
        }
    }
}

ndk::ScopedAStatus Composer::createClient(std::shared_ptr<c3::IComposerClient>* client) {
    std::lock_guard lock(mMutex);
    if (!mClient.expired()) {
        return serviceError(c3::IComposerClient::EX_NO_RESOURCES);
    }
    auto created = ndk::SharedRefBase::make<ComposerClient>();
    mClient = created;
    *client = std::move(created);
    return ndk::ScopedAStatus::ok();
}

ndk::ScopedAStatus Composer::getCapabilities(std::vector<c3::Capability>* capabilities) {
    capabilities->clear();
    return ndk::ScopedAStatus::ok();
}

}  // namespace royd::graphics::composer
