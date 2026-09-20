#!/bin/sh
set -eu

container=${1:-royd}
timeout=${2:-${ROYD_HEALTH_TIMEOUT:-240}}

case "$timeout" in
  ''|*[!0-9]*)
    printf 'error: health timeout must be a whole number of seconds: %s\n' "$timeout" >&2
    exit 2
    ;;
esac

started=$(date +%s)
printf 'Waiting up to %s seconds for Docker health in %s\n' "$timeout" "$container"
while :; do
  running=$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null || printf false)
  [ "$running" = true ] || {
    printf 'error: container stopped before becoming healthy: %s\n' "$container" >&2
    docker logs --tail 100 "$container" >&2 2>/dev/null || true
    exit 1
  }
  health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container" 2>/dev/null || printf none)
  case "$health" in
    healthy)
      printf 'Docker health check passed in %s\n' "$container"
      exit 0
      ;;
    unhealthy)
      printf 'error: Docker health check became unhealthy: %s\n' "$container" >&2
      docker inspect -f '{{range .State.Health.Log}}{{.Output}}{{end}}' "$container" >&2 2>/dev/null || true
      exit 1
      ;;
    starting) ;;
    none)
      printf 'error: container image has no Docker health check: %s\n' "$container" >&2
      exit 1
      ;;
    *)
      printf 'error: unexpected Docker health state %s for %s\n' "$health" "$container" >&2
      exit 1
      ;;
  esac
  now=$(date +%s)
  [ $((now - started)) -lt "$timeout" ] || {
    printf 'error: Docker health check did not pass within %s seconds: %s\n' "$timeout" "$container" >&2
    exit 1
  }
  sleep 2
done
