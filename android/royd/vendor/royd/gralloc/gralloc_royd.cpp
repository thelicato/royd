#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <unistd.h>

#include <cutils/native_handle.h>
#include <cutils/properties.h>
#include <hardware/gralloc.h>
#include <hardware/hardware.h>
#include <log/log.h>

#ifndef MFD_CLOEXEC
#define MFD_CLOEXEC 0x0001U
#endif
#ifndef MFD_ALLOW_SEALING
#define MFD_ALLOW_SEALING 0x0002U
#endif

namespace {

constexpr int kHandleFds = 1;
constexpr int kHandleInts = 1;

int create_memfd(const char* name, size_t size) {
#ifdef SYS_memfd_create
    int fd = static_cast<int>(syscall(SYS_memfd_create, name, MFD_CLOEXEC | MFD_ALLOW_SEALING));
#else
    errno = ENOSYS;
    int fd = -1;
#endif
    if (fd < 0) {
        return -errno;
    }
    if (ftruncate(fd, static_cast<off_t>(size)) != 0) {
        int error = -errno;
        close(fd);
        return error;
    }
    return fd;
}

size_t bytes_per_pixel(int format) {
    switch (format) {
        case HAL_PIXEL_FORMAT_RGBA_8888:
        case HAL_PIXEL_FORMAT_RGBX_8888:
        case HAL_PIXEL_FORMAT_BGRA_8888:
            return 4;
        case HAL_PIXEL_FORMAT_RGB_888:
            return 3;
        case HAL_PIXEL_FORMAT_RGB_565:
        case HAL_PIXEL_FORMAT_RAW16:
            return 2;
        case HAL_PIXEL_FORMAT_BLOB:
            return 1;
        default:
            return 0;
    }
}

int handle_size(buffer_handle_t handle) {
    if (handle == nullptr || handle->numFds != kHandleFds || handle->numInts != kHandleInts) {
        return -EINVAL;
    }
    return handle->data[1];
}

int royd_register_buffer(const gralloc_module_t*, buffer_handle_t) {
    return 0;
}

int royd_unregister_buffer(const gralloc_module_t*, buffer_handle_t) {
    return 0;
}

int royd_lock(const gralloc_module_t*, buffer_handle_t handle, int, int, int, int, int, void** vaddr) {
    if (vaddr == nullptr) {
        return -EINVAL;
    }
    int size = handle_size(handle);
    if (size <= 0) {
        return size;
    }
    void* mapping = mmap(nullptr, static_cast<size_t>(size), PROT_READ | PROT_WRITE, MAP_SHARED, handle->data[0], 0);
    if (mapping == MAP_FAILED) {
        return -errno;
    }
    *vaddr = mapping;
    return 0;
}

int royd_unlock(const gralloc_module_t*, buffer_handle_t) {
    // The legacy gralloc API has no address argument on unlock. SurfaceFlinger and
    // SwiftShader keep mappings short-lived in the software path, so this initial
    // allocator intentionally leaves mappings for process teardown. Replace this
    // with mapper-owned lifetime tracking once clean AOSP builds prove the ABI.
    return 0;
}

int royd_alloc(alloc_device_t*, int width, int height, int format, int, buffer_handle_t* out_handle, int* out_stride) {
    if (width <= 0 || height <= 0 || out_handle == nullptr || out_stride == nullptr) {
        return -EINVAL;
    }
    size_t bpp = bytes_per_pixel(format);
    if (bpp == 0) {
        return -EINVAL;
    }
    size_t stride = static_cast<size_t>(width);
    size_t size = stride * static_cast<size_t>(height) * bpp;
    if (size > static_cast<size_t>(INT32_MAX)) {
        return -EOVERFLOW;
    }
    int fd = create_memfd("royd-gralloc", size);
    if (fd < 0) {
        return fd;
    }
    native_handle_t* handle = native_handle_create(kHandleFds, kHandleInts);
    if (handle == nullptr) {
        close(fd);
        return -ENOMEM;
    }
    handle->data[0] = fd;
    handle->data[1] = static_cast<int>(size);
    *out_handle = handle;
    *out_stride = static_cast<int>(stride);
    return 0;
}

int royd_free(alloc_device_t*, buffer_handle_t handle) {
    if (handle == nullptr) {
        return -EINVAL;
    }
    native_handle_close(handle);
    native_handle_delete(const_cast<native_handle_t*>(handle));
    return 0;
}

int royd_gralloc_close(hw_device_t* device) {
    free(device);
    return 0;
}

int royd_fb_post(framebuffer_device_t*, buffer_handle_t) {
    return 0;
}

int royd_fb_set_swap_interval(framebuffer_device_t*, int) {
    return 0;
}

int property_int(const char* name, int fallback) {
    char value[PROPERTY_VALUE_MAX] = {};
    if (property_get(name, value, "") <= 0) {
        return fallback;
    }
    char* end = nullptr;
    long parsed = strtol(value, &end, 10);
    if (end == value || *end != '\0' || parsed <= 0 || parsed > INT32_MAX) {
        return fallback;
    }
    return static_cast<int>(parsed);
}

int royd_gralloc_open(const hw_module_t* module, const char* name, hw_device_t** out_device) {
    if (out_device == nullptr) {
        return -EINVAL;
    }
    if (strcmp(name, GRALLOC_HARDWARE_GPU0) == 0) {
        auto* device = static_cast<alloc_device_t*>(calloc(1, sizeof(alloc_device_t)));
        if (device == nullptr) {
            return -ENOMEM;
        }
        device->common.tag = HARDWARE_DEVICE_TAG;
        device->common.version = 0;
        device->common.module = const_cast<hw_module_t*>(module);
        device->common.close = royd_gralloc_close;
        device->alloc = royd_alloc;
        device->free = royd_free;
        *out_device = &device->common;
        return 0;
    }
    if (strcmp(name, GRALLOC_HARDWARE_FB0) == 0) {
        auto* device = static_cast<framebuffer_device_t*>(calloc(1, sizeof(framebuffer_device_t)));
        if (device == nullptr) {
            return -ENOMEM;
        }
        const int width = property_int("ro.boot.royd_width", 540);
        const int height = property_int("ro.boot.royd_height", 960);
        const int dpi = property_int("ro.boot.royd_dpi", 240);
        const int fps = property_int("ro.boot.royd_fps", 30);
        device->common.tag = HARDWARE_DEVICE_TAG;
        device->common.version = 0;
        device->common.module = const_cast<hw_module_t*>(module);
        device->common.close = royd_gralloc_close;
        device->flags = 0;
        device->width = width;
        device->height = height;
        device->stride = width;
        device->format = HAL_PIXEL_FORMAT_RGBA_8888;
        device->xdpi = static_cast<float>(dpi);
        device->ydpi = static_cast<float>(dpi);
        device->fps = static_cast<float>(fps);
        device->minSwapInterval = 0;
        device->maxSwapInterval = 1;
        device->setSwapInterval = royd_fb_set_swap_interval;
        device->post = royd_fb_post;
        *out_device = &device->common;
        return 0;
    }
    return -EINVAL;
}

hw_module_methods_t royd_gralloc_methods = {
    .open = royd_gralloc_open,
};

}  // namespace

gralloc_module_t HAL_MODULE_INFO_SYM = {
    .common = {
        .tag = HARDWARE_MODULE_TAG,
        .module_api_version = GRALLOC_MODULE_API_VERSION_0_3,
        .hal_api_version = 0,
        .id = GRALLOC_HARDWARE_MODULE_ID,
        .name = "royd memfd graphics allocator",
        .author = "royd",
        .methods = &royd_gralloc_methods,
    },
    .registerBuffer = royd_register_buffer,
    .unregisterBuffer = royd_unregister_buffer,
    .lock = royd_lock,
    .unlock = royd_unlock,
};
