#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
compose_file="$repo_root/runtime/compose.yaml"
env_file="$repo_root/runtime/.env"
graphics_backend=${ROYD_GRAPHICS_BACKEND:-}
if [ -z "$graphics_backend" ] && [ -f "$env_file" ]; then
  graphics_backend=$(sed -n 's/^ROYD_GRAPHICS_BACKEND=//p' "$env_file" | tail -n 1)
fi
graphics_backend=${graphics_backend:-software}

security_mode=${ROYD_SECURITY_MODE:-}
if [ -z "$security_mode" ] && [ -f "$env_file" ]; then
  security_mode=$(sed -n 's/^ROYD_SECURITY_MODE=//p' "$env_file" | tail -n 1)
fi
security_mode=${security_mode:-privileged}

case "$security_mode:$graphics_backend" in
  privileged:software) files="-f $compose_file" ;;
  experimental:software) files="-f $compose_file -f $repo_root/runtime/compose.experimental.yaml" ;;
  privileged:host-gpu-*) files="-f $compose_file -f $repo_root/runtime/compose.gpu.yaml" ;;
  experimental:host-gpu-*) files="-f $compose_file -f $repo_root/runtime/compose.experimental.yaml -f $repo_root/runtime/compose.gpu.yaml" ;;
  *:*)
    case "$security_mode" in privileged|experimental) ;; *) printf 'error: unknown ROYD_SECURITY_MODE: %s\n' "$security_mode" >&2; exit 2 ;; esac
    printf 'error: unknown ROYD_GRAPHICS_BACKEND: %s\n' "$graphics_backend" >&2
    exit 2
    ;;
esac
if [ -f "$env_file" ]; then
  # Word splitting is intentional for trusted repository compose paths.
  # shellcheck disable=SC2086
  exec docker compose --env-file "$env_file" $files "$@"
fi
# shellcheck disable=SC2086
exec docker compose $files "$@"
