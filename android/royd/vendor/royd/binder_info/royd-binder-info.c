#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>

static int print_identity(const char *path) {
    struct stat st;
    if (stat(path, &st) != 0) {
        fprintf(stderr, "%s: %s\n", path, strerror(errno));
        return 1;
    }
    if (!S_ISCHR(st.st_mode)) {
        fprintf(stderr, "%s: not a character device\n", path);
        return 1;
    }
    printf("%s=%llu\n", path, (unsigned long long)st.st_rdev);
    return 0;
}

int main(int argc, char **argv) {
    static const char *const defaults[] = {
        "/dev/binderfs/binder-control",
        "/dev/binder",
        "/dev/hwbinder",
        "/dev/vndbinder",
    };
    int status = 0;

    if (argc > 1) {
        for (int i = 1; i < argc; ++i) {
            status |= print_identity(argv[i]);
        }
        return status;
    }

    for (size_t i = 0; i < sizeof(defaults) / sizeof(defaults[0]); ++i) {
        status |= print_identity(defaults[i]);
    }
    return status;
}
