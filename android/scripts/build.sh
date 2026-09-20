#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1091
. "$script_dir/common.sh"

src=$(source_dir)
arch=${1:-x86_64}
profile=${2:-${ROYD_ANDROID_PROFILE:-standard}}
profile=$($script_dir/profile.sh "$profile")
hal_profile=${ROYD_HAL_PROFILE:-graphical}
hal_profile=$("$script_dir/hal-profile.sh" "$hal_profile")
graphics_backend=${ROYD_GRAPHICS_BACKEND:-software}
graphics_backend=$(ROYD_GRAPHICS_ARCH="$arch" "$script_dir/graphics-backend.sh" "$graphics_backend" "$arch")
profile_policy=$(ROYD_ANDROID_VERSION="$ANDROID_VERSION" "$script_dir/profile-policy.sh" "$profile")
profile_policy_sha256=$(ROYD_ANDROID_VERSION="$ANDROID_VERSION" "$script_dir/profile-packages.sh" "$profile" | sha256sum | awk '{print $1}')
jobs=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '4')}

[ -d "$src/build" ] || fail "Android source tree not found at $src; run android/scripts/sync.sh first"

if [ "${ROYD_CLEAN_BUILD:-0}" = 1 ]; then
  printf 'Removing previous Android build output for clean validation: %s/out\n' "$src"
  rm -rf "$src/out"
fi

case "$arch" in
  x86_64)
    product=$ANDROID_PRODUCT_X86_64
    ;;
  arm64)
    product=$ANDROID_PRODUCT_ARM64
    ;;
  *)
    fail "unsupported architecture: $arch; expected x86_64 or arm64"
    ;;
esac

ROYD_GRAPHICS_BACKEND="$graphics_backend" ROYD_GRAPHICS_ARCH="$arch" "$script_dir/install-royd.sh" "$src" "$profile"
lunch_target=$("$script_dir/lunch-target.sh" "$arch")
stamp_dir="$repo_root/.work/android-profile"
stamp="$stamp_dir/$ANDROID_VERSION-$arch"
previous_profile=
[ -f "$stamp" ] && previous_profile=$(cat "$stamp")
mkdir -p "$stamp_dir"
current_profile="$profile:$profile_policy:$profile_policy_sha256:$hal_profile:$graphics_backend"
printf 'Building Android %s (%s) with image profile %s, HAL profile %s, graphics backend %s and %s jobs\n' "$ANDROID_VERSION" "$lunch_target" "$profile" "$hal_profile" "$graphics_backend" "$jobs"

(
  cd "$src"
  # build/envsetup.sh is intentionally sourced in the same shell as lunch and m.
  # shellcheck disable=SC1091
  . build/envsetup.sh
  lunch "$lunch_target"
  if [ -n "$previous_profile" ] && [ "$previous_profile" != "$current_profile" ]; then
    printf 'Android build profile changed from %s to %s; running installclean\n' "$previous_profile" "$current_profile"
    m installclean
  fi
  m -j"$jobs"
)
printf '%s\n' "$current_profile" > "$stamp"
