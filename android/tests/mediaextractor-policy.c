/* Copyright 2026 The royd Authors. SPDX-License-Identifier: Apache-2.0 */
#define _GNU_SOURCE
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/memfd.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <sys/prctl.h>
#include <sys/resource.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <unistd.h>
#include "syscall_filter.h"
#include "util.h"

static void region_sequence(void) {
    int probe = syscall(SYS_memfd_create, "royd-probe", 9);
    if (probe < 0 || fcntl(probe, F_ADD_SEALS, F_SEAL_FUTURE_WRITE)) _exit(10);
    close(probe);
    int fd = syscall(SYS_memfd_create, "royd-region", 9);
    if (fd < 0 || ftruncate(fd, 65536)) _exit(11);
    if (fcntl(fd, F_ADD_SEALS, F_SEAL_GROW | F_SEAL_SHRINK)) _exit(12);
    int seals = fcntl(fd, F_GET_SEALS);
    // MFD_NOEXEC_SEAL installs F_SEAL_EXEC (0x20) on the supported kernel.
    if ((seals & 0x26) != 0x26) _exit(13);
    errno = 0;
    if (ftruncate(fd, 65537) != -1 || errno != EPERM) _exit(14);
    char* memory = mmap(NULL, 65536, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (memory == MAP_FAILED) _exit(15);
    if (fcntl(fd, F_ADD_SEALS, F_SEAL_FUTURE_WRITE | F_SEAL_SEAL)) _exit(16);
    memory[0] = 1;  // Existing writable mappings retain the stock ashmem semantics.
    errno = 0;
    void* another = mmap(NULL, 65536, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (another != MAP_FAILED || errno != EPERM) _exit(17);
    errno = 0;
    if (write(fd, "x", 1) != -1 || errno != EPERM) _exit(18);
    munmap(memory, 65536);
    close(fd);
}

static void denied(int signal) {
    (void)signal;
    _exit(42);
}

static int run(const struct sock_fprog* filter, int operation, uint64_t value) {
    pid_t pid = fork();
    assert(pid >= 0);
    if (pid == 0) {
        struct sigaction action = { .sa_handler = denied };
        sigemptyset(&action.sa_mask);
        if (sigaction(SIGSYS, &action, NULL)) _exit(92);
        if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0)
                || prctl(PR_SET_SECCOMP, 2 /* SECCOMP_MODE_FILTER */, filter)) _exit(90);
        if (operation == 0) region_sequence();
        else if (operation == 1) syscall(SYS_memfd_create, "royd-denied", value);
        else {
            int fd = syscall(SYS_memfd_create, "royd-denied", 9);
            if (fd < 0) _exit(91);
            if (operation == 2) syscall(SYS_fcntl, fd, F_ADD_SEALS, value);
            if (operation == 3) syscall(SYS_fcntl, fd, value, 0);
            if (operation == 4) syscall(SYS_ftruncate, fd, value);
            close(fd);
        }
        _exit(0);
    }
    int status;
    assert(waitpid(pid, &status, 0) == pid);
    return status;
}

int main(int argc, char** argv) {
    assert(argc == 2);
    init_logging(LOG_TO_FD, STDERR_FILENO, LOG_INFO);
    const struct rlimit no_core = {0, 0};
    assert(!setrlimit(RLIMIT_CORE, &no_core));
    for (int logging = 0; logging <= 1; ++logging) {
        FILE* input = fopen(argv[1], "r");
        assert(input);
        struct filter_options options = { .action = ACTION_RET_TRAP,
            .allow_logging = logging, .allow_syscalls_for_logging = logging,
            .allow_duplicate_syscalls = true };
        struct sock_fprog filter;
        assert(!compile_filter(argv[1], input, &filter, &options));
        fclose(input);
        assert(run(&filter, 0, 0) == 0);
        unsigned checks = 1;
        for (uint64_t flags = 0; flags < 64; ++flags) {
            if (flags == 9) continue;
            int status = run(&filter, 1, flags);
            assert(WIFEXITED(status) && WEXITSTATUS(status) == 42);
            ++checks;
        }
        int high_flags = run(&filter, 1, (UINT64_C(1) << 32) | 9);
        assert(WIFEXITED(high_flags) && WEXITSTATUS(high_flags) == 42);
        ++checks;
        int status = run(&filter, 4, UINT64_MAX);
        assert(WIFEXITED(status) && WEXITSTATUS(status) == 42);
        ++checks;
        if (!logging) {
            for (uint64_t seals = 0; seals < 64; ++seals) {
                if (seals == 6 || seals == 16 || seals == 17) continue;
                status = run(&filter, 2, seals);
                assert(WIFEXITED(status) && WEXITSTATUS(status) == 42);
                ++checks;
            }
            const uint64_t commands[] = {F_GETFD, F_SETFD, F_SETFL, F_DUPFD, F_DUPFD_CLOEXEC};
            for (size_t i = 0; i < sizeof(commands) / sizeof(commands[0]); ++i) {
                status = run(&filter, 3, commands[i]);
                assert(WIFEXITED(status) && WEXITSTATUS(status) == 42);
                ++checks;
            }
        } else {
            // Preserve Minijail's pre-existing diagnostic fcntl allowance.
            assert(run(&filter, 3, F_GETFD) == 0);
            ++checks;
        }
        printf("Actual Minijail compiler and kernel seccomp: logging=%d, %u checks passed\n", logging, checks);
        free(filter.filter);
    }
}
