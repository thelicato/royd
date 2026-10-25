#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
patch=$root/android/patches/android-15.0.0_r36/0069-mediaextractor-select-sealed-memfd-policy.patch
policy=$root/android/royd/vendor/royd/seccomp_policy/royd-mediaextractor-x86_64.policy
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
awk '
  /^diff --git / {copy=0}
  $0 == "+++ b/frameworks/av/services/mediaextractor/RoydMediaExtractorPolicy.h" {copy=1;next}
  copy && /^\+[^+]/ {print substr($0,2)}
  copy && $0 == "+" {print ""}
' "$patch" >"$tmp/RoydMediaExtractorPolicy.h"
test -s "$tmp/RoydMediaExtractorPolicy.h"
mkdir -p "$tmp/android-base"
cat >"$tmp/android-base/properties.h" <<'CPP'
#pragma once
#include <string>
namespace android::base {
inline bool GetBoolProperty(const std::string& key, bool fallback) {
    return fakeProperty(key, fallback);
}
}
CPP
${CXX:-c++} -std=c++17 -Wall -Wextra -Werror -I"$tmp" \
  "$root/android/tests/mediaextractor-gate.cpp" -o "$tmp/gate"
"$tmp/gate"
grep -Fq '+        SetUpMinijailWithRequiredPolicy(kSystemSeccompPolicyPath, kVendorSeccompPolicyPath,' "$patch"
! grep -q '^@include ' "$policy"
grep -Fxq 'memfd_create: arg1 == 0x9' "$policy"
grep -Fxq 'ftruncate: arg1 <= 0x7fffffffffffffff' "$policy"
cat >"$tmp/product.mk" <<EOF
include $root/android/royd/vendor/royd/royd.mk
all:
	@printf '%s\n' '\$(PRODUCT_COPY_FILES)'
EOF
for selection in 15:royd_x86_64 15:royd_arm64 14:royd_x86_64 16:royd_x86_64; do
  version=${selection%%:*}
  product=${selection#*:}
  make -s -f "$tmp/product.mk" ROYD_ANDROID_VERSION="$version" TARGET_PRODUCT="$product" TARGET_COPY_OUT_VENDOR=vendor >"$tmp/product-files"
  if [ "$selection" = 15:royd_x86_64 ]; then
    grep -Fq 'vendor/royd/seccomp_policy/royd-mediaextractor-x86_64.policy:vendor/etc/seccomp_policy/royd-mediaextractor-x86_64.policy' "$tmp/product-files"
  else
    ! grep -Fq 'royd-mediaextractor-x86_64.policy' "$tmp/product-files"
  fi
done
if [ -n "${ROYD_TEST_MEDIA_TREE:-}" ]; then
  cmp "$tmp/RoydMediaExtractorPolicy.h" "$ROYD_TEST_MEDIA_TREE/frameworks/av/services/mediaextractor/RoydMediaExtractorPolicy.h"
  python3 "$root/android/tests/mediaextractor-policy-test.py" "$ROYD_TEST_MEDIA_TREE" "$tmp" "$policy"
else
  printf '%s\n' 'Actual Minijail compiler/kernel policy test: not run (set ROYD_TEST_MEDIA_TREE)'
fi
printf '%s\n' 'Android 15 mediaextractor memfd gate passed (144 combinations)'
