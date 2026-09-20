#include <fcntl.h>
#include <sys/syscall.h>
#include <unistd.h>

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
#ifndef F_SEAL_SHRINK
#define F_SEAL_SHRINK 0x0002
#endif
#ifndef F_SEAL_GROW
#define F_SEAL_GROW 0x0004
#endif
#ifndef __NR_memfd_create
#if defined(__x86_64__)
#define __NR_memfd_create 319
#elif defined(__aarch64__)
#define __NR_memfd_create 279
#else
#error "royd memfd probe supports x86_64 and arm64 only"
#endif
#endif

int main(void) {
    int fd = (int)syscall(__NR_memfd_create, "royd-memfd-probe", MFD_CLOEXEC | MFD_ALLOW_SEALING);
    if (fd < 0) {
        return 1;
    }
    if (ftruncate(fd, 4096) < 0) {
        close(fd);
        return 1;
    }
    if (fcntl(fd, F_ADD_SEALS, F_SEAL_GROW | F_SEAL_SHRINK) < 0) {
        close(fd);
        return 1;
    }
    if (fcntl(fd, F_GET_SEALS) < 0) {
        close(fd);
        return 1;
    }
    close(fd);
    return 0;
}
