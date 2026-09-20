#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1091
. "$script_dir/common.sh"

contract="$android_dir/build-contract.env"
[ -f "$contract" ] || fail "missing build contract"

for board in \
  "$android_dir/royd/device/royd/royd_x86_64/BoardConfig.mk" \
  "$android_dir/royd/device/royd/royd_arm64/BoardConfig.mk"; do
  [ -f "$board" ] || fail "missing board config: $board"
  while IFS='=' read -r name expected; do
    case "$name" in
      ''|'#'*) continue ;;
    esac
    grep -Eq "^[[:space:]]*$name[[:space:]]*:=[[:space:]]*$expected([[:space:]]*)$" "$board" || {
      printf 'error: %s does not explicitly set %s := %s\n' "$board" "$name" "$expected" >&2
      exit 1
    }
  done < "$contract"
done

grep -Fq 'PRODUCT_USE_DYNAMIC_PARTITION_SIZE := true' "$android_dir/royd/device/royd/container_common.mk"
printf '%s\n' 'Android static build contract checks passed'
