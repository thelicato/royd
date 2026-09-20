#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
compose_file="$repo_root/runtime/compose.yaml"
env_file="$repo_root/runtime/.env"

if [ -f "$env_file" ]; then
    exec docker compose --env-file "$env_file" -f "$compose_file" "$@"
fi

exec docker compose -f "$compose_file" "$@"
