#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
mode=${2:-${ROYD_SECURITY_MODE:-privileged}}
container=${1:-royd}

command -v docker >/dev/null 2>&1 || {
  printf '%s\n' 'error: docker is required for security evidence collection' >&2
  exit 1
}

docker inspect "$container" >/dev/null 2>&1 || {
  printf 'error: container not found: %s\n' "$container" >&2
  exit 1
}

profile_id=$($script_dir/security-profile.sh "$mode" id)
profile_sha256=$($script_dir/security-profile.sh "$mode" digest)
privileged=$(docker inspect --format '{{.HostConfig.Privileged}}' "$container")
cap_add=$(docker inspect --format '{{range .HostConfig.CapAdd}}{{printf "%s," .}}{{end}}' "$container" | sed 's/,$//')
cap_drop=$(docker inspect --format '{{range .HostConfig.CapDrop}}{{printf "%s," .}}{{end}}' "$container" | sed 's/,$//')
security_opt=$(docker inspect --format '{{range .HostConfig.SecurityOpt}}{{printf "%s," .}}{{end}}' "$container" | sed 's/,$//')
apparmor=$(docker inspect --format '{{.AppArmorProfile}}' "$container")

status=$(docker exec "$container" cat /proc/1/status 2>/dev/null) || {
  printf '%s\n' 'error: could not read /proc/1/status inside container' >&2
  exit 1
}
field() {
  printf '%s\n' "$status" | sed -n "s/^$1:[[:space:]]*//p" | head -n 1
}

printf 'SECURITY_PROFILE_ID=%s\n' "$profile_id"
printf 'SECURITY_PROFILE_SHA256=%s\n' "$profile_sha256"
printf 'DOCKER_PRIVILEGED=%s\n' "$privileged"
printf 'DOCKER_CAP_ADD=%s\n' "${cap_add:-none}"
printf 'DOCKER_CAP_DROP=%s\n' "${cap_drop:-none}"
printf 'DOCKER_SECURITY_OPT=%s\n' "${security_opt:-default}"
printf 'APPARMOR_PROFILE=%s\n' "${apparmor:-none}"
printf 'PID1_CAP_INH=%s\n' "$(field CapInh)"
printf 'PID1_CAP_PRM=%s\n' "$(field CapPrm)"
printf 'PID1_CAP_EFF=%s\n' "$(field CapEff)"
printf 'PID1_CAP_BND=%s\n' "$(field CapBnd)"
printf 'PID1_CAP_AMB=%s\n' "$(field CapAmb)"
printf 'PID1_NO_NEW_PRIVS=%s\n' "$(field NoNewPrivs)"
printf 'PID1_SECCOMP=%s\n' "$(field Seccomp)"
printf 'PID1_SECCOMP_FILTERS=%s\n' "$(field Seccomp_filters)"
