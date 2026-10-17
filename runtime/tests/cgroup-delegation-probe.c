/* Diagnostic fixture only. Never installed in the runtime image. */
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static void pause_seconds(int seconds) {
    struct timespec remaining = {.tv_sec = seconds};
    while (nanosleep(&remaining, &remaining) < 0 && errno == EINTR) {}
}

int main(int argc, char** argv) {
    if (argc == 2 && strcmp(argv[1], "gate") == 0) {
        pause_seconds(2);
        char* args[] = {"/system/bin/bootstrap/linker64", "/system/bin/sh",
                        "/royd-entrypoint", NULL};
        execv(args[0], args);
        return 127;
    }
    if (argc == 3 && strcmp(argv[1], "hold") == 0) {
        char* end;
        long seconds = strtol(argv[2], &end, 10);
        if (*end || seconds < 1 || seconds > 30) return 2;
        pause_seconds((int)seconds);
        return 0;
    }
    return 2;
}
