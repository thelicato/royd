#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

report="$tmp/report.md"
ROYD_MATRIX_SOURCE_ROOT="$tmp" ROYD_MATRIX_OUTPUT="$report" "$script_dir/matrix-report.sh" >/dev/null

grep -Fq '| 8.0 | `android-8.0.0_r36` | legacy | legacy | x86_64 | missing | not-run | not-run | not-run | not-run | legacy-configured |' "$report"
grep -Fq '| 15 | `android-15.0.0_r36` | modern | modern | arm64 | missing | not-run | not-run | not-run | not-run | baseline |' "$report"
grep -Fq '| 17 | `android-17.0.0_r1` | modern | modern | x86_64 | missing | not-run | not-run | not-run | not-run | configured |' "$report"
rows=$(grep -c '^| ' "$report")
[ "$rows" -eq 24 ] || {
  printf 'error: compatibility matrix has %s table rows, expected 24 including headers\n' "$rows" >&2
  exit 1
}

if ROYD_MATRIX_SOURCE_ROOT="$tmp" ROYD_MATRIX_STRICT=1 "$script_dir/matrix-report.sh" >/dev/null 2>&1; then
  printf '%s\n' 'error: strict compatibility matrix accepted missing AOSP trees' >&2
  exit 1
fi

# Exercise resolved configuration through one mocked source tree. The existing
# config-check test covers every release, while this proves report integration.
src="$tmp/android-src-15"
mkdir -p "$src/build" "$src/system/core/libcutils"
printf '%s\n' 'mock ashmem backend' > "$src/system/core/libcutils/ashmem-dev.c"
cat > "$src/build/envsetup.sh" <<'MOCK'
lunch() {
  case "$1" in
    royd_x86_64-bp1a-userdebug) MOCK_PRODUCT=royd_x86_64; MOCK_ARCH=x86_64 ;;
    royd_arm64-bp1a-userdebug) MOCK_PRODUCT=royd_arm64; MOCK_ARCH=arm64 ;;
    *) return 1 ;;
  esac
}
get_build_var() {
  case "$1" in
    TARGET_PRODUCT|TARGET_DEVICE) printf '%s\n' "$MOCK_PRODUCT" ;;
    TARGET_ARCH) printf '%s\n' "$MOCK_ARCH" ;;
    TARGET_NO_BOOTLOADER|TARGET_NO_KERNEL) printf '%s\n' true ;;
    BOARD_SYSTEMIMAGE_FILE_SYSTEM_TYPE|BOARD_VENDORIMAGE_FILE_SYSTEM_TYPE|BOARD_SYSTEM_EXTIMAGE_FILE_SYSTEM_TYPE|BOARD_PRODUCTIMAGE_FILE_SYSTEM_TYPE) printf '%s\n' ext4 ;;
    TARGET_COPY_OUT_VENDOR) printf '%s\n' vendor ;;
    TARGET_COPY_OUT_SYSTEM_EXT) printf '%s\n' system_ext ;;
    TARGET_COPY_OUT_PRODUCT) printf '%s\n' product ;;
    *) return 1 ;;
  esac
}
MOCK

ROYD_MATRIX_SOURCE_ROOT="$tmp" ROYD_MATRIX_OUTPUT="$report" "$script_dir/matrix-report.sh" >/dev/null
grep -Fq '| 15 | `android-15.0.0_r36` | modern | modern | x86_64 | present | pass | not-run | not-run | not-run | baseline |' "$report"
grep -Fq '| 15 | `android-15.0.0_r36` | modern | modern | arm64 | present | pass | not-run | not-run | not-run | baseline |' "$report"

mkdir -p "$tmp/build-results/15"
cat > "$tmp/build-results/15/x86_64-standard-graphical.env" <<'RESULT'
RESULT_FORMAT=1
ANDROID_VERSION=15
ARCH=x86_64
IMAGE_PROFILE=standard
HAL_PROFILE=graphical
CONFIG_STATUS=pass
BUILD_STATUS=pass
PACKAGE_STATUS=pass
RESULT_STATUS=pass
RESULT
ROYD_MATRIX_SOURCE_ROOT="$tmp" ROYD_MATRIX_OUTPUT="$report" "$script_dir/matrix-report.sh" >/dev/null
grep -Fq '| 15 | `android-15.0.0_r36` | modern | modern | x86_64 | present | pass | pass | pass | not-run | package-validated |' "$report"

mkdir -p "$tmp/runtime-results/15"
cat > "$tmp/runtime-results/15/x86_64-standard-graphical-privileged.env" <<'RESULT'
RESULT_FORMAT=1
ANDROID_VERSION=15
ARCH=x86_64
IMAGE_PROFILE=standard
HAL_PROFILE=graphical
SECURITY_MODE=privileged
RESULT_STATUS=pass
RESULT
ROYD_MATRIX_SOURCE_ROOT="$tmp" ROYD_MATRIX_OUTPUT="$report" "$script_dir/matrix-report.sh" >/dev/null
grep -Fq '| 15 | `android-15.0.0_r36` | modern | modern | x86_64 | present | pass | pass | pass | pass | runtime-qualified |' "$report"

if ROYD_MATRIX_SOURCE_ROOT="$tmp" ROYD_MATRIX_REQUIRE_RUNTIME=1 "$script_dir/matrix-report.sh" >/dev/null 2>&1; then
  printf '%s\n' 'error: runtime-required compatibility matrix accepted missing runtime evidence' >&2
  exit 1
fi

if ROYD_MATRIX_SOURCE_ROOT="$tmp" ROYD_MATRIX_REQUIRE_BUILD=1 "$script_dir/matrix-report.sh" >/dev/null 2>&1; then
  printf '%s\n' 'error: build-required compatibility matrix accepted missing build evidence' >&2
  exit 1
fi

printf '%s\n' 'Android compatibility matrix report test passed'
