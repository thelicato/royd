#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1091
. "$script_dir/common.sh"

src=$(source_dir)
arch=${1:-x86_64}
profile=${2:-${ROYD_ANDROID_PROFILE:-standard}}
profile=$($script_dir/profile.sh "$profile")
jobs=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '4')}

[ -d "$src/build" ] || fail "Android source tree not found at $src; run android/scripts/sync.sh first"

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

"$script_dir/install-royd.sh" "$src" "$profile"
lunch_target=$("$script_dir/lunch-target.sh" "$arch")
stamp_dir="$repo_root/.work/android-profile"
stamp="$stamp_dir/$ANDROID_VERSION-$arch"
previous_profile=
[ -f "$stamp" ] && previous_profile=$(cat "$stamp")
mkdir -p "$stamp_dir"
printf 'Building Android %s (%s) with profile %s and %s jobs\n' "$ANDROID_VERSION" "$lunch_target" "$profile" "$jobs"

(
  cd "$src"
  # build/envsetup.sh is intentionally sourced in the same shell as lunch and m.
  # shellcheck disable=SC1091
  . build/envsetup.sh
  lunch "$lunch_target"
  if [ -n "$previous_profile" ] && [ "$previous_profile" != "$profile" ]; then
    printf 'Android profile changed from %s to %s; running installclean\n' "$previous_profile" "$profile"
    m installclean
  fi
  m -j"$jobs"
)
printf '%s\n' "$profile" > "$stamp"
