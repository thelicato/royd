#include <algorithm>
#include <atomic>
#include <cassert>
#include <cerrno>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <sys/stat.h>
#include <vector>

#ifdef ROYD_TEST_NON_X86
#undef __x86_64__
#endif
#define VKAPI_ATTR
#define ATRACE_CALL() ((void)0)
#define ALOGV(...) ((void)0)
#define ALOGV_IF(...) ((void)0)
#define ALOGI(message) recordMarker(message)
#define VK_NULL_HANDLE 0
using VkResult = int;
using VkSemaphore = uint64_t;
using VkFence = uint64_t;
using VkPipelineStageFlags = uint32_t;
using VkPresentModeKHR = int;
constexpr int VK_SUCCESS = 0;
constexpr int VK_STRUCTURE_TYPE_PRESENT_INFO_KHR = 1;
constexpr int VK_STRUCTURE_TYPE_PRESENT_REGIONS_KHR = 2;
constexpr int VK_STRUCTURE_TYPE_PRESENT_TIMES_INFO_GOOGLE = 3;
constexpr int VK_STRUCTURE_TYPE_SWAPCHAIN_PRESENT_FENCE_INFO_EXT = 4;
constexpr int VK_STRUCTURE_TYPE_SWAPCHAIN_PRESENT_MODE_INFO_EXT = 5;
constexpr int VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRIVER_PROPERTIES = 6;
constexpr int VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2 = 7;
constexpr int VK_STRUCTURE_TYPE_SUBMIT_INFO = 8;
constexpr int VK_DRIVER_ID_GOOGLE_SWIFTSHADER = 10;
constexpr VkPipelineStageFlags VK_PIPELINE_STAGE_ALL_COMMANDS_BIT = 0x10000;
struct Physical {};
struct Queue {};
using VkPhysicalDevice = Physical*;
using VkQueue = Queue*;
struct Swapchain { int id; bool mailbox_mode; };
using VkSwapchainKHR = Swapchain*;
struct VkPresentRegionKHR { int id; };
struct VkPresentTimeGOOGLE { int id; };
struct VkPresentRegionsKHR {
    int sType; const void* pNext; uint32_t swapchainCount; const VkPresentRegionKHR* pRegions;
};
struct VkPresentTimesInfoGOOGLE {
    int sType; const void* pNext; uint32_t swapchainCount; const VkPresentTimeGOOGLE* pTimes;
};
struct VkSwapchainPresentFenceInfoEXT {
    int sType; const void* pNext; uint32_t swapchainCount; const VkFence* pFences;
};
struct VkSwapchainPresentModeInfoEXT {
    int sType; const void* pNext; uint32_t swapchainCount; const VkPresentModeKHR* pPresentModes;
};
struct VkPresentInfoKHR {
    int sType; const void* pNext; uint32_t waitSemaphoreCount; const VkSemaphore* pWaitSemaphores;
    uint32_t swapchainCount; const VkSwapchainKHR* pSwapchains;
    const uint32_t* pImageIndices; VkResult* pResults;
};
struct VkPhysicalDeviceDriverProperties { int sType; void* pNext; int driverID; };
struct VkPhysicalDeviceProperties2 { int sType; void* pNext; };
struct VkSubmitInfo {
    int sType; const void* pNext; uint32_t waitSemaphoreCount;
    const VkSemaphore* pWaitSemaphores; const VkPipelineStageFlags* pWaitDstStageMask;
    uint32_t commandBufferCount; const void* pCommandBuffers;
    uint32_t signalSemaphoreCount; const VkSemaphore* pSignalSemaphores;
};

const char* environment = "1";
int probeError = ENOENT, selectedDriver = VK_DRIVER_ID_GOOGLE_SWIFTSHADER;
int queries = 0, submits = 0, markers = 0;
VkResult submitResult = VK_SUCCESS;
std::vector<VkSemaphore> queuedWaits;
std::vector<unsigned> releaseWaitCounts;
std::vector<VkResult> releaseResults;
const VkPresentRegionKHR* regionsExpected;
const VkPresentTimeGOOGLE* timesExpected;
const VkFence* fencesExpected;
const VkPresentModeKHR* modesExpected;
Queue queueObject;
Physical physicalObject;

const char* testGetenv(const char* name) {
    assert(!strcmp(name, "ROYD_CONTAINER")); return environment;
}
int testStat(const char* name, struct stat*) {
    assert(!strcmp(name, "/sys/fs/selinux/enforce"));
    errno = probeError; return probeError ? -1 : 0;
}
void properties(VkPhysicalDevice physical, VkPhysicalDeviceProperties2* value) {
    assert(physical == &physicalObject);
    assert(value->sType == VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2);
    auto* driver = static_cast<VkPhysicalDeviceDriverProperties*>(value->pNext);
    assert(driver->sType == VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRIVER_PROPERTIES);
    assert(driver->pNext == nullptr); driver->driverID = selectedDriver; ++queries;
}
VkResult submit(VkQueue queue, uint32_t count, const VkSubmitInfo* info, VkFence fence) {
    assert(queue == &queueObject && count == 1 && fence == VK_NULL_HANDLE);
    assert(info->sType == VK_STRUCTURE_TYPE_SUBMIT_INFO && !info->pNext);
    assert(!info->commandBufferCount && !info->pCommandBuffers);
    assert(!info->signalSemaphoreCount && !info->pSignalSemaphores);
    assert(releaseWaitCounts.empty()); ++submits;
    for (uint32_t i = 0; i < info->waitSemaphoreCount; ++i) {
        assert(info->pWaitDstStageMask[i] == VK_PIPELINE_STAGE_ALL_COMMANDS_BIT);
        queuedWaits.push_back(info->pWaitSemaphores[i]);
    }
    return submitResult;
}
struct Driver {
    decltype(&properties) GetPhysicalDeviceProperties2 = properties;
    decltype(&submit) QueueSubmit = submit;
};
struct Data { Driver driver; VkPhysicalDevice driver_physical_device = &physicalObject; } data;
Data& GetData(VkQueue queue) { assert(queue == &queueObject); return data; }
Data& GetData(VkPhysicalDevice physical) { assert(physical == &physicalObject); return data; }
Swapchain* SwapchainFromHandle(VkSwapchainKHR value) { return value; }
VkResult WorstPresentResult(VkResult a, VkResult b) { return std::min(a, b); }
void recordMarker(const char* value) {
    assert(!strcmp(value, "ROYD: consuming software Vulkan presentation semaphores once per batch"));
    ++markers;
}
VkResult PresentOneSwapchain(VkQueue queue, Swapchain& chain, uint32_t image,
                            const VkPresentRegionKHR* region, const VkPresentTimeGOOGLE* time,
                            VkFence fence, const VkPresentModeKHR* mode,
                            uint32_t count, const VkSemaphore* semaphores) {
    assert(queue == &queueObject && image == unsigned(chain.id + 3));
    assert(region == (regionsExpected && !chain.mailbox_mode ? &regionsExpected[chain.id] : nullptr));
    assert(time == (timesExpected ? &timesExpected[chain.id] : nullptr));
    assert(fence == (fencesExpected ? fencesExpected[chain.id] : VK_NULL_HANDLE));
    assert(mode == (modesExpected ? &modesExpected[chain.id] : nullptr));
    assert(count ? semaphores != nullptr : semaphores == nullptr);
    releaseWaitCounts.push_back(count); return releaseResults.at(chain.id);
}
namespace Stock {
// INSERT_STOCK_PRESENT
}
namespace Patched {
#define getenv(name) testGetenv(name)
#define stat(name, value) testStat(name, value)
// INSERT_CONTAINER_GATE
// INSERT_PATCHED_PRESENT
#undef stat
#undef getenv
}

void reset() {
    environment = "1"; probeError = ENOENT; selectedDriver = VK_DRIVER_ID_GOOGLE_SWIFTSHADER;
    queries = submits = 0; submitResult = VK_SUCCESS; data.driver.GetPhysicalDeviceProperties2 = properties;
    queuedWaits.clear(); releaseWaitCounts.clear(); releaseResults = {0, 0};
    regionsExpected = nullptr; timesExpected = nullptr; fencesExpected = nullptr; modesExpected = nullptr;
}
using Present = VkResult (*)(VkQueue, const VkPresentInfoKHR*);
void call(Present fn, unsigned waits, unsigned chains, bool submitted, bool metadata = false,
          VkResult expected = VK_SUCCESS, bool resultArray = true) {
    Swapchain first{0, false}, second{1, true}; VkSwapchainKHR handles[] = {&first, &second};
    uint32_t images[] = {3, 4}; VkSemaphore semaphores[] = {41, 42}; VkResult results[] = {99, 99};
    VkPresentRegionKHR regions[] = {{1}, {2}}; VkPresentTimeGOOGLE times[] = {{3}, {4}};
    VkFence fences[] = {51, 52}; VkPresentModeKHR modes[] = {61, 62};
    VkSwapchainPresentModeInfoEXT modeInfo{VK_STRUCTURE_TYPE_SWAPCHAIN_PRESENT_MODE_INFO_EXT, nullptr, chains, modes};
    VkSwapchainPresentFenceInfoEXT fenceInfo{VK_STRUCTURE_TYPE_SWAPCHAIN_PRESENT_FENCE_INFO_EXT, &modeInfo, chains, fences};
    VkPresentTimesInfoGOOGLE timeInfo{VK_STRUCTURE_TYPE_PRESENT_TIMES_INFO_GOOGLE, &fenceInfo, chains, times};
    VkPresentRegionsKHR regionInfo{VK_STRUCTURE_TYPE_PRESENT_REGIONS_KHR, &timeInfo, chains, regions};
    if (metadata) {
        regionsExpected = regions; timesExpected = times; fencesExpected = fences; modesExpected = modes;
    }
    VkPresentInfoKHR info{VK_STRUCTURE_TYPE_PRESENT_INFO_KHR, metadata ? &regionInfo : nullptr,
                         waits, waits ? semaphores : nullptr, chains, handles, images,
                         resultArray ? results : nullptr};
    assert(fn(&queueObject, &info) == expected);
    assert(submits == int(submitted));
    if (submitted) assert(queuedWaits == std::vector<VkSemaphore>(semaphores, semaphores + waits));
    else assert(queuedWaits.empty());
    if (submitResult == VK_SUCCESS || !submitted) {
        assert(releaseWaitCounts.size() == chains);
        for (unsigned i = 0; i < chains; ++i) {
            assert(releaseWaitCounts[i] == (submitted ? 0 : waits));
            if (resultArray) assert(results[i] == releaseResults[i]);
        }
    } else {
        assert(releaseWaitCounts.empty());
        if (resultArray) for (unsigned i = 0; i < chains; ++i) assert(results[i] == submitResult);
    }
    assert(info.waitSemaphoreCount == waits && info.pWaitSemaphores == (waits ? semaphores : nullptr));
}
int main() {
    reset(); call(Stock::QueuePresentKHR, 2, 2, false, true);
    assert(submits == 0 && releaseWaitCounts == std::vector<unsigned>({2, 2}));
    for (const char* value : {static_cast<const char*>(nullptr), "", "0", "01", "true"}) {
        reset(); environment = value; call(Patched::QueuePresentKHR, 2, 2, false, true); assert(queries == 0);
    }
    for (int error : {0, EACCES, ENOTDIR, EIO}) {
        reset(); probeError = error; call(Patched::QueuePresentKHR, 1, 1, false); assert(queries == 0);
    }
    reset(); data.driver.GetPhysicalDeviceProperties2 = nullptr; call(Patched::QueuePresentKHR, 1, 1, false);
    reset(); selectedDriver = 999; call(Patched::QueuePresentKHR, 1, 1, false);
    reset(); call(Patched::QueuePresentKHR, 0, 2, false, true); assert(queries == 0);
    reset(); call(Patched::QueuePresentKHR, 2, 0, false); assert(queries == 0);
#ifdef ROYD_TEST_NON_X86
    reset(); call(Patched::QueuePresentKHR, 2, 2, false, true); assert(queries == 0 && markers == 0);
#else
    reset(); submitResult = -4; call(Patched::QueuePresentKHR, 2, 2, true, true, -4); assert(markers == 0);
    reset(); submitResult = -1; call(Patched::QueuePresentKHR, 1, 1, true, false, -1, false); assert(markers == 0);
    reset(); call(Patched::QueuePresentKHR, 1, 1, true); assert(markers == 1);
    reset(); call(Patched::QueuePresentKHR, 2, 2, true, true); assert(markers == 1);
    reset(); releaseResults = {-2, -3}; call(Patched::QueuePresentKHR, 2, 2, true, true, -3);
    reset(); call(Patched::QueuePresentKHR, 1, 2, true, false, 0, false); assert(markers == 1);
#endif
    std::cout << "Vulkan presentation wait contracts passed\n";
}
