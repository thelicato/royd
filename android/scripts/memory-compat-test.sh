#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

check_overlay() {
  version=$1
  extension=$2
  tree="$tmp/$version"
  mkdir -p "$tree/system/core/libcutils"
  printf '%s\n' 'upstream ashmem implementation' > "$tree/system/core/libcutils/ashmem-dev.$extension"
  ROYD_ANDROID_VERSION="$version" "$script_dir/install-memory-compat.sh" "$tree"
  grep -Fq 'royd legacy ashmem API compatibility backed by memfd' "$tree/system/core/libcutils/ashmem-dev.$extension"
  ! grep -Fq 'upstream ashmem implementation' "$tree/system/core/libcutils/ashmem-dev.$extension"
}

check_overlay 8.0 c
check_overlay 8.1 c
check_overlay 9 c
check_overlay 10 cpp

modern="$tmp/11"
mkdir -p "$modern/system/core/libcutils"
printf '%s\n' 'native memfd implementation' > "$modern/system/core/libcutils/ashmem-dev.cpp"
ROYD_ANDROID_VERSION=11 "$script_dir/install-memory-compat.sh" "$modern"
grep -Fq 'native memfd implementation' "$modern/system/core/libcutils/ashmem-dev.cpp"

compat="$script_dir/../compat/memory/ashmem-dev.c"
grep -Fq '__NR_memfd_create' "$compat"
grep -Fq 'F_ADD_SEALS' "$compat"
legacy_device=$(printf '/dev/%s' 'ashmem')
! grep -Fq "$legacy_device" "$compat"

command -v cc >/dev/null 2>&1 || { printf '%s\n' 'error: cc is required for memory compatibility tests' >&2; exit 1; }
command -v c++ >/dev/null 2>&1 || { printf '%s\n' 'error: c++ is required for memory compatibility tests' >&2; exit 1; }
mkdir -p "$tmp/include/cutils" "$tmp/include/log"
cat > "$tmp/include/cutils/ashmem.h" <<'HDR'
#pragma once
#include <stddef.h>
int ashmem_valid(int fd);
int ashmem_create_region(const char* name, size_t size);
int ashmem_set_prot_region(int fd, int prot);
int ashmem_pin_region(int fd, size_t offset, size_t len);
int ashmem_unpin_region(int fd, size_t offset, size_t len);
int ashmem_get_size_region(int fd);
void ashmem_init(void);
HDR
cat > "$tmp/include/log/log.h" <<'HDR'
#pragma once
#define ALOGE(...) do { } while (0)
HDR
cc -D_GNU_SOURCE -std=c11 -Wall -Wextra -Werror -I"$tmp/include" -c "$compat" -o "$tmp/ashmem-dev.o"
c++ -D_GNU_SOURCE -std=c++11 -Wall -Wextra -Werror -I"$tmp/include" -x c++ -c "$compat" -o "$tmp/ashmem-dev-cpp.o"
cat > "$tmp/ashmem-smoke.c" <<'SRC'
#include <sys/mman.h>
#include <unistd.h>
#include <cutils/ashmem.h>

int main(void) {
    int fd = ashmem_create_region("royd-test", 8192);
    if (fd < 0) return 1;
    if (!ashmem_valid(fd)) return 2;
    if (ashmem_get_size_region(fd) != 8192) return 3;
    if (ashmem_pin_region(fd, 0, 0) != 0) return 4;
    if (ashmem_unpin_region(fd, 0, 0) != 0) return 5;
    if (ashmem_set_prot_region(fd, PROT_READ) != 0) return 6;
    close(fd);
    return 0;
}
SRC
cc -D_GNU_SOURCE -std=c11 -Wall -Wextra -Werror -I"$tmp/include" "$tmp/ashmem-smoke.c" "$tmp/ashmem-dev.o" -o "$tmp/ashmem-smoke"
"$tmp/ashmem-smoke"
cc -D_GNU_SOURCE -std=c11 -Wall -Wextra -Werror "$script_dir/../royd/vendor/royd/memfd_probe/royd-memfd-probe.c" -o "$tmp/royd-memfd-probe"
"$tmp/royd-memfd-probe"

printf '%s\n' 'Android shared-memory compatibility checks passed'
