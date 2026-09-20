#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
default_image=$("$script_dir/default-image.sh" standard x86_64)
image=${1:-${ROYD_IMAGE:-$default_image}}
profile=${ROYD_PROFILE:-default}
modes=${ROYD_SECURITY_MODES:-'privileged experimental'}
output=${ROYD_SECURITY_SWEEP_OUTPUT:--}
workdir=$(mktemp -d)

cleanup() {
  rm -rf "$workdir"
}
trap cleanup EXIT HUP INT TERM

command -v docker >/dev/null 2>&1 || {
  printf '%s\n' 'error: docker is required for a security sweep' >&2
  exit 1
}

docker image inspect "$image" >/dev/null 2>&1 || {
  printf 'error: image not found: %s\n' "$image" >&2
  exit 1
}

: >"$workdir/results.tsv"
for mode in $modes; do
  "$script_dir/security-args.sh" "$mode" >/dev/null
  printf 'Testing security mode %s\n' "$mode" >&2

  set +e
  env ROYD_SECURITY_MODE="$mode" ROYD_PROFILE="$profile" \
    "$script_dir/smoke-test.sh" "$image" >"$workdir/$mode-single.log" 2>&1
  single_status=$?
  env ROYD_SECURITY_MODE="$mode" ROYD_PROFILE="$profile" \
    "$script_dir/multi-instance-test.sh" "$image" >"$workdir/$mode-multi.log" 2>&1
  multi_status=$?
  set -e

  printf '%s\t%s\t%s\n' "$mode" "$single_status" "$multi_status" >>"$workdir/results.tsv"
done

report="$workdir/report.md"
{
  printf '# royd security mode comparison\n\n'
  printf 'This report compares runtime validation under the configured OCI security modes. It does not prove that a passing reduced profile is minimal.\n\n'
  printf -- '- image: `%s`\n' "$image"
  printf -- '- runtime profile: `%s`\n' "$profile"
  printf -- '- security modes: `%s`\n\n' "$modes"
  printf '| Security mode | Single instance | Two instances |\n'
  printf '| --- | --- | --- |\n'
  while IFS="$(printf '\t')" read -r mode single_status multi_status; do
    [ "$single_status" -eq 0 ] && single_result=passed || single_result=failed
    [ "$multi_status" -eq 0 ] && multi_result=passed || multi_result=failed
    printf '| `%s` | %s | %s |\n' "$mode" "$single_result" "$multi_result"
  done <"$workdir/results.tsv"
  printf '\n## Diagnostics\n\n'
  while IFS="$(printf '\t')" read -r mode single_status multi_status; do
    if [ "$single_status" -eq 0 ] && [ "$multi_status" -eq 0 ]; then
      continue
    fi
    printf '### `%s`\n\n' "$mode"
    if [ "$single_status" -ne 0 ]; then
      printf 'Single-instance failure:\n\n```text\n'
      tail -n 60 "$workdir/$mode-single.log" 2>/dev/null || true
      printf '```\n\n'
    fi
    if [ "$multi_status" -ne 0 ]; then
      printf 'Two-instance failure:\n\n```text\n'
      tail -n 60 "$workdir/$mode-multi.log" 2>/dev/null || true
      printf '```\n\n'
    fi
  done <"$workdir/results.tsv"
  printf '## Interpretation\n\n'
  printf 'A passing experimental mode is evidence that the tested capability set is sufficient for this exact image, host, runtime profile, and workload. It is not evidence that every listed capability is required. Remove capabilities one at a time and rerun the same matrix before promoting a reduced default.\n'
} >"$report"

if [ "$output" = '-' ]; then
  cat "$report"
else
  mkdir -p "$(dirname -- "$output")"
  cp "$report" "$output"
  printf 'Wrote security mode comparison to %s\n' "$output"
fi
