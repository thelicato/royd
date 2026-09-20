#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

/* Keep the binderfs userspace ABI local so this helper also builds against
 * older Android source trees whose exported Linux headers predate binderfs. */
#define ROYD_BINDERFS_MAX_NAME 255
struct royd_binderfs_device {
    char name[ROYD_BINDERFS_MAX_NAME + 1];
    uint32_t major;
    uint32_t minor;
};
#define ROYD_BINDER_CTL_ADD _IOWR('b', 1, struct royd_binderfs_device)

static int add_device(int control_fd, const char *name) {
    struct royd_binderfs_device device = {0};
    size_t length = strlen(name);

    if (length == 0 || length >= sizeof(device.name)) {
        fprintf(stderr, "invalid binder device name: %s\n", name);
        return 1;
    }

    memcpy(device.name, name, length + 1);
    if (ioctl(control_fd, ROYD_BINDER_CTL_ADD, &device) < 0) {
        fprintf(stderr, "BINDER_CTL_ADD %s failed: %s\n", name, strerror(errno));
        return 1;
    }

    return 0;
}

int main(int argc, char **argv) {
    int control_fd;
    int status = 0;

    if (argc < 3) {
        fprintf(stderr, "usage: %s <binder-control> <device> [device...]\n", argv[0]);
        return 2;
    }

    control_fd = open(argv[1], O_RDONLY | O_CLOEXEC);
    if (control_fd < 0) {
        fprintf(stderr, "cannot open %s: %s\n", argv[1], strerror(errno));
        return 1;
    }

    for (int i = 2; i < argc; ++i) {
        if (add_device(control_fd, argv[i]) != 0) {
            status = 1;
        }
    }

    close(control_fd);
    return status;
}
