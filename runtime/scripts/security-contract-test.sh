#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)

privileged=$($script_dir/security-args.sh privileged)
[ "$privileged" = '--privileged' ] || {
  printf '%s\n' 'error: privileged mode did not resolve to --privileged' >&2
  exit 1
}

experimental=$($script_dir/security-args.sh experimental)
for required in SYS_ADMIN NET_ADMIN SYS_NICE SYS_RESOURCE SYS_PTRACE; do
  printf '%s\n' "$experimental" | grep -Fxq -- "--cap-add=$required" || {
    printf 'error: experimental security mode is missing %s\n' "$required" >&2
    exit 1
  }
done
printf '%s\n' "$experimental" | grep -Fq -- '--privileged' && {
  printf '%s\n' 'error: experimental security mode unexpectedly enables privileged mode' >&2
  exit 1
}

if "$script_dir/security-args.sh" unknown >/dev/null 2>&1; then
  printf '%s\n' 'error: invalid security mode unexpectedly succeeded' >&2
  exit 1
fi

grep -Fq 'privileged: false' "$repo_root/runtime/compose.experimental.yaml"
grep -Fq 'SYS_ADMIN' "$repo_root/runtime/compose.experimental.yaml"
grep -Fq 'privileged: false' "$repo_root/runtime/compose.multi.experimental.yaml"

printf '%s\n' 'Runtime security contract test passed'
