#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
profile=${1:-${ROYD_PROFILE:-default}}
profile_file="$script_dir/../profiles/$profile.env"

[ -f "$profile_file" ] || {
  printf 'error: unknown runtime profile: %s\n' "$profile" >&2
  printf 'available profiles:' >&2
  for candidate in "$script_dir"/../profiles/*.env; do
    [ -e "$candidate" ] || continue
    name=${candidate##*/}
    printf ' %s' "${name%.env}" >&2
  done
  printf '\n' >&2
  exit 2
}

# shellcheck disable=SC1090
. "$profile_file"

for variable in ROYD_WIDTH ROYD_HEIGHT ROYD_DPI ROYD_FPS; do
  eval "value=\${$variable:-}"
  case "$value" in
    ''|*[!0-9]*)
      printf 'error: %s must be a positive integer in %s\n' "$variable" "$profile_file" >&2
      exit 2
      ;;
    0)
      printf 'error: %s must be greater than zero in %s\n' "$variable" "$profile_file" >&2
      exit 2
      ;;
  esac
done

printf 'royd.width=%s\n' "$ROYD_WIDTH"
printf 'royd.height=%s\n' "$ROYD_HEIGHT"
printf 'royd.dpi=%s\n' "$ROYD_DPI"
printf 'royd.fps=%s\n' "$ROYD_FPS"
