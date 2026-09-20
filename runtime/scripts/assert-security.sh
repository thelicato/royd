#!/bin/sh
set -eu

container=${1:-royd}
mode=${2:-${ROYD_SECURITY_MODE:-privileged}}

command -v docker >/dev/null 2>&1 || {
  printf '%s\n' 'error: docker is required for security validation' >&2
  exit 1
}

docker inspect "$container" >/dev/null 2>&1 || {
  printf 'error: container not found: %s\n' "$container" >&2
  exit 1
}

privileged=$(docker inspect --format '{{.HostConfig.Privileged}}' "$container" 2>/dev/null)
cap_add=$(docker inspect --format '{{json .HostConfig.CapAdd}}' "$container" 2>/dev/null)

case "$mode" in
  privileged)
    [ "$privileged" = true ] || {
      printf 'error: %s is not running in privileged mode\n' "$container" >&2
      exit 1
    }
    ;;
  experimental)
    [ "$privileged" = false ] || {
      printf 'error: %s unexpectedly runs privileged in experimental mode\n' "$container" >&2
      exit 1
    }
    for required in SYS_ADMIN NET_ADMIN SYS_NICE SYS_RESOURCE SYS_PTRACE; do
      printf '%s\n' "$cap_add" | grep -Fq "$required" || {
        printf 'error: %s is missing required experimental capability %s\n' "$container" "$required" >&2
        exit 1
      }
    done
    ;;
  *)
    printf 'error: unknown security mode: %s\n' "$mode" >&2
    exit 2
    ;;
esac

printf 'Security checks passed: %s (%s)\n' "$container" "$mode"
