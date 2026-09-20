#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)

privileged=$($script_dir/security-args.sh privileged)
[ "$privileged" = '--privileged' ] || {
  printf '%s\n' 'error: privileged mode did not resolve to --privileged' >&2
  exit 1
}

profile_id=$($script_dir/security-profile.sh experimental id)
[ "$profile_id" = experimental-v2-exact-caps ] || {
  printf 'error: unexpected experimental security profile: %s\n' "$profile_id" >&2
  exit 1
}
profile_sha256=$($script_dir/security-profile.sh experimental digest)
printf '%s\n' "$profile_sha256" | grep -Eq '^[0-9a-f]{64}$' || {
  printf '%s\n' 'error: experimental security profile digest is not SHA-256' >&2
  exit 1
}

experimental=$($script_dir/security-args.sh experimental)
printf '%s\n' "$experimental" | grep -Fxq -- '--cap-drop=ALL' || {
  printf '%s\n' 'error: experimental mode does not reset Docker default capabilities' >&2
  exit 1
}
# shellcheck disable=SC1091
. "$repo_root/runtime/security/experimental.env"
for required in $ROYD_CAPABILITIES; do
  printf '%s\n' "$experimental" | grep -Fxq -- "--cap-add=$required" || {
    printf 'error: experimental security mode is missing %s\n' "$required" >&2
    exit 1
  }
  grep -Fq -- "- $required" "$repo_root/runtime/compose.experimental.yaml" || {
    printf 'error: Compose experimental profile is missing %s\n' "$required" >&2
    exit 1
  }
  grep -Fq "\"$required\"" "$repo_root/cli/cmd/royd/main.go" || {
    printf 'error: CLI experimental profile is missing %s\n' "$required" >&2
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

# Capability overrides are used only by the reduction sweep and must still start from an empty set.
override=$(ROYD_CAPABILITIES_OVERRIDE='SYS_ADMIN SETUID' "$script_dir/security-args.sh" experimental)
printf '%s\n' "$override" | grep -Fxq -- '--cap-drop=ALL'
printf '%s\n' "$override" | grep -Fxq -- '--cap-add=SYS_ADMIN'
printf '%s\n' "$override" | grep -Fxq -- '--cap-add=SETUID'
[ "$(printf '%s\n' "$override" | grep -c '^--cap-add=')" -eq 2 ]

grep -Fq 'privileged: false' "$repo_root/runtime/compose.experimental.yaml"
grep -Fq 'cap_drop:' "$repo_root/runtime/compose.experimental.yaml"
grep -Fq -- '- ALL' "$repo_root/runtime/compose.experimental.yaml"
grep -Fq 'privileged: false' "$repo_root/runtime/compose.multi.experimental.yaml"
grep -Fq 'cap_drop:' "$repo_root/runtime/compose.multi.experimental.yaml"
[ "$(grep -vc '^#' "$repo_root/runtime/security/experimental.capabilities" | tr -d ' ')" -eq 19 ] || {
  printf '%s\n' 'error: capability rationale inventory does not match the experimental profile' >&2
  exit 1
}

grep -Fq 'security-capability-sweep.sh' "$repo_root/Makefile"
grep -Fq 'security-evidence.sh' "$repo_root/runtime/scripts/qualification.sh"

printf '%s\n' 'Runtime security contract test passed'
