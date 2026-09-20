/*
 * royd legacy ashmem API compatibility backed by memfd.
 *
 * This file intentionally implements the libcutils ashmem API without opening
 * the legacy ashmem device. It is installed only into Android releases whose libcutils
 * still requires the removed ashmem kernel driver.
 */
#define LOG_TAG "ashmem"

#include <errno.h>
#include <fcntl.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <unistd.h>

#include <cutils/ashmem.h>
#include <log/log.h>

#ifndef MFD_CLOEXEC
#define MFD_CLOEXEC 0x0001U
#endif
#ifndef MFD_ALLOW_SEALING
#define MFD_ALLOW_SEALING 0x0002U
#endif
#ifndef F_ADD_SEALS
#define F_ADD_SEALS 1033
#endif
#ifndef F_GET_SEALS
#define F_GET_SEALS 1034
#endif
#ifndef F_SEAL_SEAL
#define F_SEAL_SEAL 0x0001
#endif
#ifndef F_SEAL_SHRINK
#define F_SEAL_SHRINK 0x0002
#endif
#ifndef F_SEAL_GROW
#define F_SEAL_GROW 0x0004
#endif
#ifndef F_SEAL_WRITE
#define F_SEAL_WRITE 0x0008
#endif
#ifndef F_SEAL_FUTURE_WRITE
#define F_SEAL_FUTURE_WRITE 0x0010
#endif

#ifndef __NR_memfd_create
#if defined(__x86_64__)
#define __NR_memfd_create 319
#elif defined(__aarch64__)
#define __NR_memfd_create 279
#else
#error "royd memfd compatibility supports x86_64 and arm64 only"
#endif
#endif

static int royd_memfd_create(const char* name, size_t size) {
    const char* region_name = name ? name : "royd-ashmem";
    int fd = (int)syscall(__NR_memfd_create, region_name, MFD_CLOEXEC | MFD_ALLOW_SEALING);
    if (fd < 0) {
        ALOGE("memfd_create(%s) failed: %s", region_name, strerror(errno));
        return -1;
    }
    if (ftruncate(fd, (off_t)size) < 0) {
        int saved_errno = errno;
        close(fd);
        errno = saved_errno;
        return -1;
    }
    if (fcntl(fd, F_ADD_SEALS, F_SEAL_GROW | F_SEAL_SHRINK) < 0) {
        int saved_errno = errno;
        close(fd);
        errno = saved_errno;
        return -1;
    }
    return fd;
}

static int royd_memfd_valid(int fd) {
    return fcntl(fd, F_GET_SEALS) >= 0;
}

int ashmem_valid(int fd) {
    return royd_memfd_valid(fd);
}

int ashmem_create_region(const char* name, size_t size) {
    return royd_memfd_create(name, size);
}

int ashmem_set_prot_region(int fd, int prot) {
    if (!royd_memfd_valid(fd)) {
        errno = ENOTTY;
        return -1;
    }
    if (prot & PROT_WRITE) {
        return 0;
    }
    if (fcntl(fd, F_ADD_SEALS, F_SEAL_FUTURE_WRITE) == 0) {
        return 0;
    }
    if (errno == EINVAL && fcntl(fd, F_ADD_SEALS, F_SEAL_WRITE) == 0) {
        return 0;
    }
    return -1;
}

int ashmem_pin_region(int fd, size_t offset, size_t len) {
    (void)offset;
    (void)len;
    if (!royd_memfd_valid(fd)) {
        errno = ENOTTY;
        return -1;
    }
    return 0;
}

int ashmem_unpin_region(int fd, size_t offset, size_t len) {
    (void)offset;
    (void)len;
    if (!royd_memfd_valid(fd)) {
        errno = ENOTTY;
        return -1;
    }
    return 0;
}

int ashmem_get_size_region(int fd) {
    struct stat st;
    if (!royd_memfd_valid(fd)) {
        errno = ENOTTY;
        return -1;
    }
    if (fstat(fd, &st) < 0) {
        return -1;
    }
    return (int)st.st_size;
}

void ashmem_init(void) {
}
