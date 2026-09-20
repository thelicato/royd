#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
image=${1:-${ROYD_IMAGE:-royd:dev}}
profile=${ROYD_PROFILE:-default}
limits=${ROYD_MEMORY_LIMITS:-'512m 640m 768m 896m 1024m'}
timeout=${ROYD_BOOT_TIMEOUT:-180}
settle=${ROYD_MEMORY_SETTLE:-10}
output=${ROYD_MEMORY_SWEEP_OUTPUT:--}
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

profile_args=$("$script_dir/profile.sh" "$profile")

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
  # Word splitting is intentional because profile.sh emits one trusted argument per line.
  # shellcheck disable=SC2086
  docker run -d --privileged \
    --name "$container" \
    --memory "$limit" \
    --memory-swap "$limit" \
    -v "$volume:/data" \
    "$image" $profile_args >"$log" 2>&1
  run_status=$?
  if [ "$run_status" -eq 0 ]; then
    "$script_dir/wait-for-boot.sh" "$container" "$timeout" >>"$log" 2>&1
    boot_status=$?
    if [ "$boot_status" -eq 0 ]; then
      "$script_dir/assert-runtime.sh" "$container" >>"$log" 2>&1
      assert_status=$?
      if [ "$assert_status" -eq 0 ]; then
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
    fi
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
  printf 'Testing %s with profile %s\n' "$limit" "$profile" >&2
  run_candidate "$limit"
done

report="$workdir/report.md"
{
  printf '# royd memory sweep\n\n'
  printf 'This report tests candidate container memory limits. A pass is evidence only for this exact image, host, profile, and boot workload. It is not a general minimum-RAM claim.\n\n'
  printf -- '- image: `%s`\n' "$image"
  printf -- '- profile: `%s`\n' "$profile"
  printf -- '- boot timeout: `%s seconds`\n' "$timeout"
  printf -- '- settle time: `%s seconds`\n\n' "$settle"
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
  printf 'The sweep deliberately uses a fresh `/data` volume for every candidate and constrains memory and swap to the same value. Failed candidates may have stopped because of Android boot failure, an assertion failure, the container memory limit, or another host issue.\n'
} >"$report"

if [ "$output" = '-' ]; then
  cat "$report"
else
  mkdir -p "$(dirname -- "$output")"
  cp "$report" "$output"
  printf 'Wrote memory sweep report to %s\n' "$output"
fi
