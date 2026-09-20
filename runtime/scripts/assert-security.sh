#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
container=${1:-royd}
mode=${2:-${ROYD_SECURITY_MODE:-privileged}}
profile="$repo_root/runtime/security/$mode.env"

command -v docker >/dev/null 2>&1 || {
  printf '%s\n' 'error: docker is required for security validation' >&2
  exit 1
}
[ -f "$profile" ] || {
  printf 'error: unknown security mode: %s\n' "$mode" >&2
  exit 2
}
# shellcheck disable=SC1090
. "$profile"

docker inspect "$container" >/dev/null 2>&1 || {
  printf 'error: container not found: %s\n' "$container" >&2
  exit 1
}

privileged=$(docker inspect --format '{{.HostConfig.Privileged}}' "$container" 2>/dev/null)
cap_add=$(docker inspect --format '{{range .HostConfig.CapAdd}}{{printf "%s\n" .}}{{end}}' "$container" 2>/dev/null | sort)
cap_drop=$(docker inspect --format '{{range .HostConfig.CapDrop}}{{printf "%s\n" .}}{{end}}' "$container" 2>/dev/null | sort)

if [ "$ROYD_SECURITY_PRIVILEGED" = 1 ]; then
  [ "$privileged" = true ] || {
    printf 'error: %s is not running in privileged mode\n' "$container" >&2
    exit 1
  }
else
  [ "$privileged" = false ] || {
    printf 'error: %s unexpectedly runs privileged in %s mode\n' "$container" "$mode" >&2
    exit 1
  }

  if [ "$ROYD_CAP_DROP_ALL" = 1 ]; then
    printf '%s\n' "$cap_drop" | grep -Fxq 'ALL' || {
      printf 'error: %s does not drop the Docker capability baseline before applying %s\n' "$container" "$mode" >&2
      exit 1
    }
  fi

  expected_capabilities=$ROYD_CAPABILITIES
  if [ "${ROYD_CAPABILITIES_OVERRIDE+x}" = x ]; then
    expected_capabilities=$ROYD_CAPABILITIES_OVERRIDE
  fi
  expected=$(for capability in $expected_capabilities; do printf '%s\n' "$capability"; done | sort)
  [ "$cap_add" = "$expected" ] || {
    printf 'error: %s capability set does not match security profile %s\n' "$container" "$ROYD_SECURITY_PROFILE_ID" >&2
    printf '%s\n' 'expected:' >&2
    printf '%s\n' "$expected" >&2
    printf '%s\n' 'actual:' >&2
    printf '%s\n' "$cap_add" >&2
    exit 1
  }
fi

printf 'Security checks passed: %s (%s, %s)\n' "$container" "$mode" "$ROYD_SECURITY_PROFILE_ID"
