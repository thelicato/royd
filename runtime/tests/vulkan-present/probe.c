// Android 15 synchronous SwiftShader presentation diagnostic, outside the product image.
#include <android/hardware_buffer.h>
#include <errno.h>
#include <media/NdkImageReader.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <vulkan/vulkan.h>

#define CHECK(call)                                                                                \
    do {                                                                                           \
        fprintf(stderr, "begin %s\n", #call);                                                      \
        VkResult r = (call);                                                                       \
        fprintf(stderr, "end %s: %d\n", #call, r);                                                 \
        if (r != VK_SUCCESS) {                                                                     \
            fprintf(stderr, "%s: %d\n", #call, r);                                                 \
            return 2;                                                                              \
        }                                                                                          \
    } while (0)
#define LOAD(name)                                                                                 \
    PFN_##name name = (PFN_##name)get(instance, #name);                                            \
    if (!name) {                                                                                   \
        fprintf(stderr, "Missing %s\n", #name);                                                    \
        return 2;                                                                                  \
    }
struct HostSignal {
    PFN_vkSignalSemaphoreKHR signal;
    VkDevice device;
    VkSemaphore timeline;
    atomic_int issued;
    VkResult result;
};
static void *signal_later(void *data) {
    struct HostSignal *job = data;
    for (unsigned phase = 1; phase <= 2; ++phase) {
        struct timespec delay = {.tv_nsec = 200000000};
        int result;
        do {
            result = nanosleep(&delay, &delay);
        } while (result == -1 && errno == EINTR);
        if (result != 0) {
            job->result = VK_ERROR_UNKNOWN;
            return NULL;
        }
        VkSemaphoreSignalInfo info = {.sType = VK_STRUCTURE_TYPE_SEMAPHORE_SIGNAL_INFO,
                                      .semaphore = job->timeline,
                                      .value = phase};
        atomic_store_explicit(&job->issued, (1 << phase) - 1, memory_order_release);
        job->result = job->signal(job->device, &info);
        if (job->result != VK_SUCCESS)
            return NULL;
    }
    return NULL;
}
static unsigned argument(const char *text, unsigned maximum) {
    char *end = NULL;
    errno = 0;
    unsigned long value = strtoul(text, &end, 10);
    if (errno || !*text || *end || value > maximum) {
        fprintf(stderr, "Invalid numeric argument: %s\n", text);
        exit(2);
    }
    return (unsigned)value;
}
int main(int argc, char **argv) {
    if (argc != 4) {
        fprintf(stderr, "usage: probe WAIT_COUNT SWAPCHAIN_COUNT EXPLICIT_WAIT_SUBMISSION\n");
        return 2;
    }
    unsigned count = argument(argv[1], 2), chains = argument(argv[2], 2);
    int manual = (int)argument(argv[3], 1);
    if (!chains)
        return 2;
    PFN_vkGetInstanceProcAddr get = vkGetInstanceProcAddr;
    VkInstance instance = VK_NULL_HANDLE;
    LOAD(vkCreateInstance);
    VkApplicationInfo app = {.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
                             .pApplicationName = "royd release semaphore diagnostic",
                             .apiVersion = VK_API_VERSION_1_1};
    const char *iext[] = {VK_KHR_SURFACE_EXTENSION_NAME, VK_KHR_ANDROID_SURFACE_EXTENSION_NAME};
    VkInstanceCreateInfo ici = {.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
                                .pApplicationInfo = &app,
                                .enabledExtensionCount = 2,
                                .ppEnabledExtensionNames = iext};
    CHECK(vkCreateInstance(&ici, NULL, &instance));
    LOAD(vkEnumeratePhysicalDevices);
    LOAD(vkGetPhysicalDeviceProperties);
    LOAD(vkGetPhysicalDeviceProperties2);
    LOAD(vkCreateDevice);
    LOAD(vkGetDeviceProcAddr);
    uint32_t n = 1;
    VkPhysicalDevice physical;
    CHECK(vkEnumeratePhysicalDevices(instance, &n, &physical));
    if (n != 1)
        return 2;
    VkPhysicalDeviceProperties properties;
    vkGetPhysicalDeviceProperties(physical, &properties);
    VkPhysicalDeviceDriverProperties identity = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRIVER_PROPERTIES};
    VkPhysicalDeviceProperties2 properties2 = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2, .pNext = &identity};
    vkGetPhysicalDeviceProperties2(physical, &properties2);
    printf("driver=%s driver_id=%d api=%u\n", properties.deviceName, identity.driverID,
           properties.apiVersion);
    if (properties.deviceType != VK_PHYSICAL_DEVICE_TYPE_CPU ||
        identity.driverID != VK_DRIVER_ID_GOOGLE_SWIFTSHADER) {
        fprintf(stderr, "Probe requires the Android 15 software SwiftShader baseline\n");
        return 2;
    }
    float priority = 1;
    VkDeviceQueueCreateInfo qi = {.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
                                  .queueFamilyIndex = 0,
                                  .queueCount = 1,
                                  .pQueuePriorities = &priority};
    const char *extensions[] = {VK_KHR_SWAPCHAIN_EXTENSION_NAME,
                                VK_KHR_EXTERNAL_SEMAPHORE_FD_EXTENSION_NAME};
    VkDeviceCreateInfo di = {.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
                             .queueCreateInfoCount = 1,
                             .pQueueCreateInfos = &qi,
                             .enabledExtensionCount = 2,
                             .ppEnabledExtensionNames = extensions};
    VkDevice device;
    CHECK(vkCreateDevice(physical, &di, NULL, &device));
    LOAD(vkGetDeviceQueue);
    LOAD(vkCreateSemaphore);
    LOAD(vkCreateCommandPool);
    LOAD(vkAllocateCommandBuffers);
    LOAD(vkBeginCommandBuffer);
    LOAD(vkCmdPipelineBarrier);
    LOAD(vkEndCommandBuffer);
    LOAD(vkQueueSubmit);
    LOAD(vkQueueWaitIdle);
    LOAD(vkCreateAndroidSurfaceKHR);
    LOAD(vkGetPhysicalDeviceSurfaceCapabilitiesKHR);
    LOAD(vkCreateSwapchainKHR);
    LOAD(vkGetSwapchainImagesKHR);
    LOAD(vkAcquireNextImageKHR);
    LOAD(vkQueuePresentKHR);
    LOAD(vkCmdClearColorImage);
    VkQueue queue;
    vkGetDeviceQueue(device, 0, 0, &queue);
    AImageReader *readers[2] = {0};
    VkSurfaceKHR surfaces[2];
    VkSwapchainKHR swapchains[2];
    VkImage images[2];
    uint32_t indices[2];
    VkSemaphore acquired[2];
    VkSemaphoreCreateInfo plain = {.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};
    VkCommandPoolCreateInfo pi = {.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
                                  .queueFamilyIndex = 0};
    VkCommandPool pool;
    CHECK(vkCreateCommandPool(device, &pi, NULL, &pool));
    VkCommandBufferAllocateInfo ai = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
                                      .commandPool = pool,
                                      .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
                                      .commandBufferCount = 1};
    VkCommandBuffer command;
    CHECK(vkAllocateCommandBuffers(device, &ai, &command));
    VkCommandBufferBeginInfo bi = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
    CHECK(vkBeginCommandBuffer(command, &bi));
    VkPipelineStageFlags acquire_stages[2] = {VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,
                                              VK_PIPELINE_STAGE_ALL_COMMANDS_BIT};
    for (unsigned i = 0; i < chains; i++) {
        media_status_t status = AImageReader_newWithUsage(16, 16, AIMAGE_FORMAT_RGBA_8888,
                                                          AHARDWAREBUFFER_USAGE_GPU_COLOR_OUTPUT |
                                                              AHARDWAREBUFFER_USAGE_CPU_READ_OFTEN,
                                                          4, &readers[i]);
        if (status != AMEDIA_OK) {
            fprintf(stderr, "ImageReader allocate %d\n", status);
            return 2;
        }
        ANativeWindow *window = NULL;
        if (AImageReader_getWindow(readers[i], &window) != AMEDIA_OK)
            return 2;
        VkAndroidSurfaceCreateInfoKHR as = {
            .sType = VK_STRUCTURE_TYPE_ANDROID_SURFACE_CREATE_INFO_KHR, .window = window};
        CHECK(vkCreateAndroidSurfaceKHR(instance, &as, NULL, &surfaces[i]));
        VkSurfaceCapabilitiesKHR caps;
        CHECK(vkGetPhysicalDeviceSurfaceCapabilitiesKHR(physical, surfaces[i], &caps));
        VkCompositeAlphaFlagBitsKHR alpha =
            (VkCompositeAlphaFlagBitsKHR)(caps.supportedCompositeAlpha &
                                          (~caps.supportedCompositeAlpha + 1));
        VkSwapchainCreateInfoKHR ci = {.sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
                                       .surface = surfaces[i],
                                       .minImageCount = caps.minImageCount,
                                       .imageFormat = VK_FORMAT_R8G8B8A8_UNORM,
                                       .imageColorSpace = VK_COLOR_SPACE_SRGB_NONLINEAR_KHR,
                                       .imageExtent = {16, 16},
                                       .imageArrayLayers = 1,
                                       .imageUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT |
                                                     VK_IMAGE_USAGE_TRANSFER_DST_BIT,
                                       .imageSharingMode = VK_SHARING_MODE_EXCLUSIVE,
                                       .preTransform = caps.currentTransform,
                                       .compositeAlpha = alpha,
                                       .presentMode = VK_PRESENT_MODE_FIFO_KHR,
                                       .clipped = VK_TRUE};
        CHECK(vkCreateSwapchainKHR(device, &ci, NULL, &swapchains[i]));
        CHECK(vkCreateSemaphore(device, &plain, NULL, &acquired[i]));
        CHECK(vkAcquireNextImageKHR(device, swapchains[i], UINT64_MAX, acquired[i], VK_NULL_HANDLE,
                                    &indices[i]));
        uint32_t image_count = 0;
        CHECK(vkGetSwapchainImagesKHR(device, swapchains[i], &image_count, NULL));
        if (image_count > 16)
            return 2;
        VkImage all_images[16];
        CHECK(vkGetSwapchainImagesKHR(device, swapchains[i], &image_count, all_images));
        images[i] = all_images[indices[i]];
        VkImageMemoryBarrier barrier = {
            .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
            .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED,
            .newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
            .image = images[i],
            .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1}};
        vkCmdPipelineBarrier(command, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
                             VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 0, NULL, 1, &barrier);
        VkClearColorValue color = {
            .float32 = {i == 0 ? 1.0f : 0.0f, i == 1 ? 1.0f : 0.0f, 0.0f, 1.0f}};
        vkCmdClearColorImage(command, images[i], VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &color, 1,
                             &barrier.subresourceRange);
        barrier.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
        barrier.dstAccessMask = 0;
        barrier.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        barrier.newLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
        vkCmdPipelineBarrier(command, VK_PIPELINE_STAGE_TRANSFER_BIT,
                             VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, 0, 0, NULL, 0, NULL, 1,
                             &barrier);
    }
    CHECK(vkEndCommandBuffer(command));
    VkSubmitInfo render = {.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
                           .waitSemaphoreCount = chains,
                           .pWaitSemaphores = acquired,
                           .pWaitDstStageMask = acquire_stages,
                           .commandBufferCount = 1,
                           .pCommandBuffers = &command};
    CHECK(vkQueueSubmit(queue, 1, &render, VK_NULL_HANDLE));
    CHECK(vkQueueWaitIdle(queue));
    const char *other_extensions[] = {VK_KHR_EXTERNAL_SEMAPHORE_FD_EXTENSION_NAME,
                                      VK_KHR_TIMELINE_SEMAPHORE_EXTENSION_NAME};
    VkPhysicalDeviceTimelineSemaphoreFeatures timeline_feature = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_TIMELINE_SEMAPHORE_FEATURES,
        .timelineSemaphore = VK_TRUE};
    VkDeviceCreateInfo other_info = {.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
                                     .pNext = &timeline_feature,
                                     .queueCreateInfoCount = 1,
                                     .pQueueCreateInfos = &qi,
                                     .enabledExtensionCount = 2,
                                     .ppEnabledExtensionNames = other_extensions};
    VkDevice other;
    CHECK(vkCreateDevice(physical, &other_info, NULL, &other));
    VkQueue other_queue;
    vkGetDeviceQueue(other, 0, 0, &other_queue);
    PFN_vkGetSemaphoreFdKHR export_fd =
        (PFN_vkGetSemaphoreFdKHR)vkGetDeviceProcAddr(device, "vkGetSemaphoreFdKHR");
    PFN_vkImportSemaphoreFdKHR import_fd =
        (PFN_vkImportSemaphoreFdKHR)vkGetDeviceProcAddr(other, "vkImportSemaphoreFdKHR");
    PFN_vkSignalSemaphoreKHR host_signal =
        (PFN_vkSignalSemaphoreKHR)vkGetDeviceProcAddr(other, "vkSignalSemaphoreKHR");
    if (!export_fd || !import_fd || !host_signal)
        return 2;
    VkSemaphoreTypeCreateInfo ti = {.sType = VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO,
                                    .semaphoreType = VK_SEMAPHORE_TYPE_TIMELINE,
                                    .initialValue = 0};
    VkSemaphoreCreateInfo timeline_info = {.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
                                           .pNext = &ti};
    VkSemaphore timeline;
    CHECK(vkCreateSemaphore(other, &timeline_info, NULL, &timeline));
    VkExportSemaphoreCreateInfo ei = {.sType = VK_STRUCTURE_TYPE_EXPORT_SEMAPHORE_CREATE_INFO,
                                      .handleTypes =
                                          VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_OPAQUE_FD_BIT};
    VkSemaphoreCreateInfo si = {.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO, .pNext = &ei};
    VkSemaphore semaphores[2], imports[2];
    for (unsigned i = 0; i < 2; i++) {
        CHECK(vkCreateSemaphore(device, &si, NULL, &semaphores[i]));
        VkSemaphoreCreateInfo plain = {.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};
        CHECK(vkCreateSemaphore(other, &plain, NULL, &imports[i]));
        VkSemaphoreGetFdInfoKHR gi = {.sType = VK_STRUCTURE_TYPE_SEMAPHORE_GET_FD_INFO_KHR,
                                      .semaphore = semaphores[i],
                                      .handleType =
                                          VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_OPAQUE_FD_BIT};
        int fd;
        CHECK(export_fd(device, &gi, &fd));
        VkImportSemaphoreFdInfoKHR imp = {.sType = VK_STRUCTURE_TYPE_IMPORT_SEMAPHORE_FD_INFO_KHR,
                                          .semaphore = imports[i],
                                          .handleType =
                                              VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_OPAQUE_FD_BIT,
                                          .fd = fd};
        CHECK(import_fd(other, &imp));
    }
    // Separate pending producers make omission of either dependency observable.
    for (unsigned i = 0; i < 2; ++i) {
        uint64_t wait_value = i + 1, signal_value = 0;
        VkTimelineSemaphoreSubmitInfo tsi = {.sType =
                                                 VK_STRUCTURE_TYPE_TIMELINE_SEMAPHORE_SUBMIT_INFO,
                                             .waitSemaphoreValueCount = 1,
                                             .pWaitSemaphoreValues = &wait_value,
                                             .signalSemaphoreValueCount = 1,
                                             .pSignalSemaphoreValues = &signal_value};
        VkPipelineStageFlags stage = VK_PIPELINE_STAGE_ALL_COMMANDS_BIT;
        VkSubmitInfo pending_signal = {.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
                                       .pNext = &tsi,
                                       .waitSemaphoreCount = 1,
                                       .pWaitSemaphores = &timeline,
                                       .pWaitDstStageMask = &stage,
                                       .signalSemaphoreCount = 1,
                                       .pSignalSemaphores = &imports[i]};
        CHECK(vkQueueSubmit(other_queue, 1, &pending_signal, VK_NULL_HANDLE));
    }
    struct HostSignal job = {
        .signal = host_signal, .device = other, .timeline = timeline, .issued = ATOMIC_VAR_INIT(0)};
    pthread_t signal_thread;
    if (pthread_create(&signal_thread, NULL, signal_later, &job))
        return 2;
    if (manual && count) {
        VkPipelineStageFlags stages[2] = {VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,
                                          VK_PIPELINE_STAGE_ALL_COMMANDS_BIT};
        VkSubmitInfo waits = {.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
                              .waitSemaphoreCount = count,
                              .pWaitSemaphores = semaphores,
                              .pWaitDstStageMask = stages};
        CHECK(vkQueueSubmit(queue, 1, &waits, VK_NULL_HANDLE));
    }
    VkResult results[2] = {VK_ERROR_UNKNOWN, VK_ERROR_UNKNOWN};
    VkPresentInfoKHR present = {.sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
                                .waitSemaphoreCount = manual ? 0 : count,
                                .pWaitSemaphores = manual ? NULL : semaphores,
                                .swapchainCount = chains,
                                .pSwapchains = swapchains,
                                .pImageIndices = indices,
                                .pResults = results};
    CHECK(vkQueuePresentKHR(queue, &present));
    int signal_mask = atomic_load_explicit(&job.issued, memory_order_acquire);
    int required_mask = (1 << count) - 1;
    int issued = count ? (signal_mask & required_mask) == required_mask : signal_mask != 0;
    if (pthread_join(signal_thread, NULL))
        return 2;
    CHECK(job.result);
    CHECK(vkQueueWaitIdle(other_queue));
    CHECK(vkQueueWaitIdle(queue));
    int pixels_ok = 1;
    for (unsigned i = 0; i < chains; i++) {
        AImage *image = NULL;
        media_status_t status = AImageReader_acquireNextImage(readers[i], &image);
        if (status != AMEDIA_OK) {
            fprintf(stderr, "Image acquire %d\n", status);
            return 2;
        }
        AHardwareBuffer *buffer = NULL;
        if (AImage_getHardwareBuffer(image, &buffer) != AMEDIA_OK)
            return 2;
        AHardwareBuffer_Desc desc;
        AHardwareBuffer_describe(buffer, &desc);
        void *pixels = NULL;
        if (AHardwareBuffer_lock(buffer, AHARDWAREBUFFER_USAGE_CPU_READ_OFTEN, -1, NULL, &pixels))
            return 2;
        for (unsigned y = 0; y < 16; y++)
            for (unsigned x = 0; x < 16; x++) {
                unsigned char *p = (unsigned char *)pixels + (y * desc.stride + x) * 4;
                if (p[0] != (i == 0 ? 255 : 0) || p[1] != (i == 1 ? 255 : 0) || p[2] != 0 ||
                    p[3] != 255)
                    pixels_ok = 0;
            }
        if (AHardwareBuffer_unlock(buffer, NULL))
            return 2;
        AImage_delete(image);
    }
    printf("wait_count=%u swapchains=%u explicit_wait_submission=%d returned_after_host_signal=%d "
           "expected=%d signal_mask=%d pixels_ok=%d results=",
           count, chains, manual, issued, count != 0, signal_mask, pixels_ok);
    for (unsigned i = 0; i < chains; i++)
        printf("%s%d", i ? "," : "", results[i]);
    printf("\n");
    fflush(NULL);
    // All pending producers/queues are complete; this disposable process owns every image and
    // handle.
    return issued == (count != 0) && pixels_ok ? 0 : 1;
}
