#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
compose_file="$repo_root/runtime/compose.yaml"
env_file="$repo_root/runtime/.env"
security_mode=${ROYD_SECURITY_MODE:-}
if [ -z "$security_mode" ] && [ -f "$env_file" ]; then
  security_mode=$(sed -n 's/^ROYD_SECURITY_MODE=//p' "$env_file" | tail -n 1)
fi
security_mode=${security_mode:-privileged}

case "$security_mode" in
  privileged)
    if [ -f "$env_file" ]; then
      exec docker compose --env-file "$env_file" -f "$compose_file" "$@"
    fi
    exec docker compose -f "$compose_file" "$@"
    ;;
  experimental)
    overlay="$repo_root/runtime/compose.experimental.yaml"
    if [ -f "$env_file" ]; then
      exec docker compose --env-file "$env_file" -f "$compose_file" -f "$overlay" "$@"
    fi
    exec docker compose -f "$compose_file" -f "$overlay" "$@"
    ;;
  *)
    printf 'error: unknown ROYD_SECURITY_MODE: %s\n' "$security_mode" >&2
    exit 2
    ;;
esac
