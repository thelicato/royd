#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
default_image=$("$script_dir/default-image.sh" standard x86_64)
image=${1:-${ROYD_IMAGE:-$default_image}}
profile=${ROYD_PROFILE:-$("$script_dir/default-runtime-profile.sh")}
limits=${ROYD_MEMORY_LIMITS:-'512m 640m 768m 896m 1024m'}
timeout=${ROYD_BOOT_TIMEOUT:-180}
settle=${ROYD_MEMORY_SETTLE:-10}
output=${ROYD_MEMORY_SWEEP_OUTPUT:--}
workload=${ROYD_MEMORY_WORKLOAD:-boot-idle}
workload_command=${ROYD_MEMORY_WORKLOAD_COMMAND:-}
workdir=$(mktemp -d)

cleanup() {
  rm -rf "$workdir"
}
trap cleanup EXIT HUP INT TERM

command -v docker >/dev/null 2>&1 || {
  printf '%s\n' 'error: docker is required for a memory sweep' >&2
  exit 1
}

docker image inspect "$image" >/dev/null 2>&1 || {
  printf 'error: image not found: %s\n' "$image" >&2
  exit 1
}

case "$workload" in
  ''|*[!A-Za-z0-9._-]*)
    printf 'error: ROYD_MEMORY_WORKLOAD must contain only letters, numbers, dot, underscore or dash\n' >&2
    exit 2
    ;;
esac
if [ "$workload" = boot-idle ] && [ -n "$workload_command" ]; then
  printf '%s\n' 'error: set ROYD_MEMORY_WORKLOAD to a descriptive name when ROYD_MEMORY_WORKLOAD_COMMAND is used' >&2
  exit 2
fi
if [ "$workload" != boot-idle ] && [ -z "$workload_command" ]; then
  printf '%s\n' 'error: non-default ROYD_MEMORY_WORKLOAD requires ROYD_MEMORY_WORKLOAD_COMMAND' >&2
  exit 2
fi

provenance=$("$script_dir/memory-provenance.sh" "$image" "$profile")

profile_args=$("$script_dir/profile.sh" "$profile")
security_mode=${ROYD_SECURITY_MODE:-privileged}
security_args=$("$script_dir/security-args.sh" "$security_mode")
container_args=$("$script_dir/container-args.sh")
runtime_arch=${ROYD_ARCH:-${ROYD_QUALIFY_ARCH:-x86_64}}
gpu_args=$(ROYD_GRAPHICS_ARCH="$runtime_arch" "$script_dir/gpu-args.sh" "${ROYD_GRAPHICS_BACKEND:-software}" "$runtime_arch")

case "$settle" in
  ''|*[!0-9]*)
    printf 'error: ROYD_MEMORY_SETTLE must be a whole number of seconds\n' >&2
    exit 2
    ;;
esac

run_candidate() {
  limit=$1
  safe_limit=$(printf '%s' "$limit" | tr -c 'A-Za-z0-9_.-' '_')
  container="royd-memory-${safe_limit}-$$"
  volume="${container}-data"
  log="$workdir/$safe_limit.log"

  docker rm -f "$container" >/dev/null 2>&1 || true
  docker volume rm "$volume" >/dev/null 2>&1 || true
  docker volume create "$volume" >/dev/null

  status='failed'
  usage='unavailable'
  android_ram='unavailable'
  image_profile='unknown'
  package_count='unavailable'
  started=$(date +%s)

  set +e
  # Word splitting is intentional because profile.sh and security-args.sh emit trusted arguments.
  # shellcheck disable=SC2086
  docker run -d $security_args $gpu_args $container_args \
    --name "$container" \
    --memory "$limit" \
    --memory-swap "$limit" \
    -v "$volume:/data" \
    "$image" $profile_args >"$log" 2>&1
  run_status=$?

  if [ "$run_status" -eq 0 ]; then
    "$script_dir/assert-security.sh" "$container" "$security_mode" >>"$log" 2>&1
    run_status=$?
  fi
  if [ "$run_status" -eq 0 ]; then
    "$script_dir/wait-for-boot.sh" "$container" "$timeout" >>"$log" 2>&1
    run_status=$?
  fi
  if [ "$run_status" -eq 0 ]; then
    "$script_dir/assert-runtime.sh" "$container" >>"$log" 2>&1
    run_status=$?
  fi
  if [ "$run_status" -eq 0 ] && [ -n "$workload_command" ]; then
    docker exec "$container" sh -c "$workload_command" >>"$log" 2>&1
    run_status=$?
  fi
  if [ "$run_status" -eq 0 ]; then
    [ "$settle" -eq 0 ] || sleep "$settle"
    status='passed'
    usage=$(docker stats --no-stream --format '{{.MemUsage}}' "$container" 2>/dev/null || printf '%s' unavailable)
    android_ram=$(docker exec "$container" dumpsys meminfo 2>/dev/null | sed -n 's/^[[:space:]]*Total RAM:[[:space:]]*//p' | head -n 1)
    [ -n "$android_ram" ] || android_ram='unavailable'
    image_profile=$(docker exec "$container" getprop ro.vendor.royd.image_profile 2>/dev/null || true)
    [ -n "$image_profile" ] || image_profile='unknown'
    package_count=$(docker exec "$container" sh -c 'pm list packages 2>/dev/null | wc -l' 2>/dev/null | tr -d '[:space:]' || true)
    [ -n "$package_count" ] || package_count='unavailable'
  fi
  set -e

  ended=$(date +%s)
  elapsed=$((ended - started))
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$limit" "$status" "$elapsed" "$usage" "$android_ram" "$image_profile" "$package_count" >>"$workdir/results.tsv"

  docker logs --tail 100 "$container" >"$workdir/$safe_limit-container.log" 2>&1 || true
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker volume rm "$volume" >/dev/null 2>&1 || true
}

: >"$workdir/results.tsv"
for limit in $limits; do
  case "$limit" in
    *[!0-9kKmMgG]*|'')
      printf 'error: invalid memory limit candidate: %s\n' "$limit" >&2
      exit 2
      ;;
    *[0-9]|*[0-9][kKmMgG])
      ;;
    *)
      printf 'error: invalid memory limit candidate: %s\n' "$limit" >&2
      exit 2
      ;;
  esac
  printf 'Testing %s with profile %s and workload %s\n' "$limit" "$profile" "$workload" >&2
  run_candidate "$limit"
done

report="$workdir/report.md"
{
  printf '# royd memory sweep\n\n'
  printf 'This report tests candidate container memory limits. A pass is evidence only for this exact image, host, display profile, and workload. It is not a general minimum-RAM claim.\n\n'
  printf '%s\n' "$provenance"
  printf -- '- security mode: `%s`\n' "$security_mode"
  printf -- '- workload: `%s`\n' "$workload"
  printf -- '- boot timeout: `%s seconds`\n' "$timeout"
  printf -- '- settle time: `%s seconds`\n' "$settle"
  if [ -n "$workload_command" ]; then
    printf -- '- workload command:\n\n```sh\n%s\n```\n\n' "$workload_command"
  else
    printf -- '- workload command: none (boot and idle settle only)\n\n'
  fi
  printf '| Limit | Result | Seconds | Container usage | Android total RAM | Image profile | Packages |\n'
  printf '| --- | --- | ---: | --- | --- | --- | ---: |\n'
  while IFS="$(printf '\t')" read -r limit status elapsed usage android_ram image_profile package_count; do
    printf '| `%s` | %s | %s | %s | %s | `%s` | %s |\n' "$limit" "$status" "$elapsed" "$usage" "$android_ram" "$image_profile" "$package_count"
  done <"$workdir/results.tsv"
  printf '\n## Failure diagnostics\n\n'
  found_failure=false
  while IFS="$(printf '\t')" read -r limit status elapsed usage android_ram image_profile package_count; do
    [ "$status" = failed ] || continue
    found_failure=true
    safe_limit=$(printf '%s' "$limit" | tr -c 'A-Za-z0-9_.-' '_')
    printf '### `%s`\n\n' "$limit"
    printf '```text\n'
    tail -n 40 "$workdir/$safe_limit.log" 2>/dev/null || true
    tail -n 40 "$workdir/$safe_limit-container.log" 2>/dev/null || true
    printf '```\n\n'
  done <"$workdir/results.tsv"
  if [ "$found_failure" = false ]; then
    printf 'No candidate failed during this sweep.\n\n'
  fi
  printf '## Notes\n\n'
  printf 'The sweep deliberately uses a fresh `/data` volume for every candidate and constrains memory and swap to the same value. Failed candidates may have stopped because of Android boot failure, workload failure, an assertion failure, the container memory limit, or another host issue.\n'
} >"$report"

if [ "$output" = '-' ]; then
  cat "$report"
else
  mkdir -p "$(dirname -- "$output")"
  cp "$report" "$output"
  printf 'Wrote memory sweep report to %s\n' "$output"
fi
