#!/bin/sh
set -eu

container=${1:-}
output=${2:-}

[ -n "$container" ] || {
  printf '%s\n' 'usage: container-evidence.sh CONTAINER OUTPUT_DIR' >&2
  exit 2
}
[ -n "$output" ] || {
  printf '%s\n' 'usage: container-evidence.sh CONTAINER OUTPUT_DIR' >&2
  exit 2
}
command -v docker >/dev/null 2>&1 || {
  printf '%s\n' 'error: docker is required to capture container evidence' >&2
  exit 1
}
docker inspect "$container" >/dev/null 2>&1 || {
  printf 'error: container not found: %s\n' "$container" >&2
  exit 1
}

mkdir -p "$output"
rm -f "$output/container-inspect.json" "$output/container.log" "$output/state.txt"

docker inspect "$container" > "$output/container-inspect.json"
docker inspect --format 'name={{.Name}}
id={{.Id}}
image={{.Image}}
status={{.State.Status}}
running={{.State.Running}}
exit_code={{.State.ExitCode}}
oom_killed={{.State.OOMKilled}}
error={{.State.Error}}
health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container" > "$output/state.txt"
docker logs --timestamps "$container" > "$output/container.log" 2>&1

printf 'Captured Docker inspect and full timestamped logs for %s in %s\n' "$container" "$output"
