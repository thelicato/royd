#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
default_image=$($script_dir/default-image.sh standard x86_64)
image=${1:-${ROYD_IMAGE:-$default_image}}
profile=${ROYD_PROFILE:-$($script_dir/default-runtime-profile.sh)}
output=${ROYD_SECURITY_CAPABILITY_SWEEP_OUTPUT:--}
check_image=${ROYD_SECURITY_SWEEP_CHECK_IMAGE:-1}
single_runner=${ROYD_SECURITY_SINGLE_RUNNER:-$script_dir/smoke-test.sh}
multi_runner=${ROYD_SECURITY_MULTI_RUNNER:-$script_dir/multi-instance-test.sh}
workdir=$(mktemp -d)

cleanup() { rm -rf "$workdir"; }
trap cleanup EXIT HUP INT TERM

case "$check_image" in 0|1) ;; *) printf '%s\n' 'error: ROYD_SECURITY_SWEEP_CHECK_IMAGE must be 0 or 1' >&2; exit 2 ;; esac

# shellcheck disable=SC1091
. "$repo_root/runtime/security/experimental.env"
base_caps=$ROYD_CAPABILITIES
profile_id=$($script_dir/security-profile.sh experimental id)
profile_sha256=$($script_dir/security-profile.sh experimental digest)

if [ "$check_image" = 1 ]; then
  command -v docker >/dev/null 2>&1 || {
    printf '%s\n' 'error: docker is required for a capability sweep' >&2
    exit 1
  }
  docker image inspect "$image" >/dev/null 2>&1 || {
    printf 'error: image not found: %s\n' "$image" >&2
    exit 1
  }
fi

run_case() {
  label=$1
  caps=$2
  set +e
  env ROYD_SECURITY_MODE=experimental ROYD_CAPABILITIES_OVERRIDE="$caps" ROYD_PROFILE="$profile" \
    "$single_runner" "$image" >"$workdir/$label-single.log" 2>&1
  single_status=$?
  env ROYD_SECURITY_MODE=experimental ROYD_CAPABILITIES_OVERRIDE="$caps" ROYD_PROFILE="$profile" \
    "$multi_runner" "$image" >"$workdir/$label-multi.log" 2>&1
  multi_status=$?
  set -e
  printf '%s\t%s\t%s\t%s\n' "$label" "$single_status" "$multi_status" "$caps" >> "$workdir/results.tsv"
}

: > "$workdir/results.tsv"
run_case baseline "$base_caps"
for dropped in $base_caps; do
  remaining=
  for capability in $base_caps; do
    [ "$capability" = "$dropped" ] && continue
    if [ -n "$remaining" ]; then
      remaining="$remaining $capability"
    else
      remaining=$capability
    fi
  done
  run_case "without-$dropped" "$remaining"
done

baseline_single=$(awk -F '\t' '$1 == "baseline" {print $2}' "$workdir/results.tsv")
baseline_multi=$(awk -F '\t' '$1 == "baseline" {print $3}' "$workdir/results.tsv")

report="$workdir/report.md"
{
  printf '# royd experimental capability reduction sweep\n\n'
  printf 'This report removes one capability at a time from the exact experimental profile and reruns the same single-instance and two-instance validation. A passing removal is only a candidate for further qualification, not proof that the capability is universally unnecessary.\n\n'
  printf -- '- image: `%s`\n' "$image"
  printf -- '- runtime profile: `%s`\n' "$profile"
  printf -- '- security profile: `%s`\n' "$profile_id"
  printf -- '- security profile SHA-256: `%s`\n\n' "$profile_sha256"
  printf '| Case | Single instance | Two instances | Interpretation |\n'
  printf '| --- | --- | --- | --- |\n'
  while IFS="$(printf '\t')" read -r label single_status multi_status caps; do
    [ "$single_status" -eq 0 ] && single_result=passed || single_result=failed
    [ "$multi_status" -eq 0 ] && multi_result=passed || multi_result=failed
    if [ "$label" = baseline ]; then
      if [ "$single_status" -eq 0 ] && [ "$multi_status" -eq 0 ]; then interpretation='baseline passed'; else interpretation='baseline failed'; fi
    elif [ "$single_status" -eq 0 ] && [ "$multi_status" -eq 0 ]; then
      interpretation='candidate for removal'
    else
      interpretation='keep pending deeper diagnosis'
    fi
    printf '| `%s` | %s | %s | %s |\n' "$label" "$single_result" "$multi_result" "$interpretation"
  done < "$workdir/results.tsv"
  printf '\n## Failure diagnostics\n\n'
  while IFS="$(printf '\t')" read -r label single_status multi_status caps; do
    if [ "$single_status" -eq 0 ] && [ "$multi_status" -eq 0 ]; then
      continue
    fi
    printf '### `%s`\n\n' "$label"
    printf 'Capabilities used: `%s`\n\n' "$caps"
    if [ "$single_status" -ne 0 ]; then
      printf 'Single-instance failure:\n\n```text\n'
      tail -n 50 "$workdir/$label-single.log" 2>/dev/null || true
      printf '```\n\n'
    fi
    if [ "$multi_status" -ne 0 ]; then
      printf 'Two-instance failure:\n\n```text\n'
      tail -n 50 "$workdir/$label-multi.log" 2>/dev/null || true
      printf '```\n\n'
    fi
  done < "$workdir/results.tsv"
} > "$report"

if [ "$output" = '-' ]; then
  cat "$report"
else
  mkdir -p "$(dirname -- "$output")"
  cp "$report" "$output"
  printf 'Wrote capability reduction sweep to %s\n' "$output"
fi

if [ "$baseline_single" -ne 0 ] || [ "$baseline_multi" -ne 0 ]; then
  printf '%s\n' 'error: experimental baseline failed; capability-removal candidates are not valid evidence' >&2
  exit 1
fi
