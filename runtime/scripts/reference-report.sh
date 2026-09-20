#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
image=${1:-${ROYD_IMAGE:-royd:dev}}
profile=${ROYD_PROFILE:-default}
output=${ROYD_REPORT_OUTPUT:--}
workdir=$(mktemp -d)

cleanup() {
  rm -rf "$workdir"
}
trap cleanup EXIT HUP INT TERM

command -v docker >/dev/null 2>&1 || {
  printf '%s\n' 'error: docker is required to collect a reference-host report' >&2
  exit 1
}

capture() {
  name=$1
  shift
  set +e
  "$@" >"$workdir/$name.out" 2>&1
  status=$?
  set -e
  printf '%s' "$status" >"$workdir/$name.status"
}

first_existing_kernel_config() {
  kernel=$(uname -r)
  for path in "/proc/config.gz" "/boot/config-$kernel" "/lib/modules/$kernel/build/.config"; do
    if [ -r "$path" ]; then
      printf '%s\n' "$path"
      return 0
    fi
  done
  return 1
}

read_kernel_config() {
  path=$1
  case "$path" in
    *.gz) gzip -cd "$path" 2>/dev/null || true ;;
    *) cat "$path" 2>/dev/null || true ;;
  esac
}

format_command_result() {
  title=$1
  name=$2
  status=$(cat "$workdir/$name.status")
  printf '### %s\n\n' "$title"
  printf 'Exit status: `%s`\n\n' "$status"
  printf '```text\n'
  cat "$workdir/$name.out"
  printf '\n```\n\n'
}

capture docker_version docker version
capture docker_info docker info
capture smoke env ROYD_PROFILE="$profile" "$script_dir/smoke-test.sh" "$image"
capture multi env ROYD_PROFILE="$profile" "$script_dir/multi-instance-test.sh" "$image"

kernel_config_path=''
if kernel_config_path=$(first_existing_kernel_config); then
  read_kernel_config "$kernel_config_path" | grep -E '^(CONFIG_ANDROID_BINDER_IPC|CONFIG_ANDROID_BINDERFS|CONFIG_MEMCG|CONFIG_PSI|CONFIG_NAMESPACES|CONFIG_SECCOMP|CONFIG_DMABUF_HEAPS)=' >"$workdir/kernel-config.out" || true
else
  printf '%s\n' 'kernel configuration not readable from common locations' >"$workdir/kernel-config.out"
fi

if [ -f /sys/fs/cgroup/cgroup.controllers ]; then
  cgroup_mode='v2'
else
  cgroup_mode='v1 or hybrid'
fi

if grep -q '[[:space:]]binder$' /proc/filesystems 2>/dev/null; then
  binderfs='advertised'
else
  binderfs='not advertised'
fi

if [ -d /dev/dri ]; then
  gpu_state='/dev/dri present'
else
  gpu_state='/dev/dri not present'
fi

if command -v git >/dev/null 2>&1 && git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  royd_commit=$(git -C "$root" rev-parse HEAD 2>/dev/null || printf '%s' unknown)
else
  royd_commit='unknown'
fi

android_baseline=$(sed -n 's/^AOSP_TAG=//p' "$root/android/baseline.env" | head -n 1)
architecture=$(uname -m)
kernel=$(uname -srmo)
os_release='unknown'
if [ -r /etc/os-release ]; then
  os_release=$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release | head -n 1 | sed 's/^"//;s/"$//')
fi
cpu_model='unknown'
if [ -r /proc/cpuinfo ]; then
  cpu_model=$(sed -n 's/^model name[[:space:]]*:[[:space:]]*//p' /proc/cpuinfo | head -n 1)
  [ -n "$cpu_model" ] || cpu_model=$(sed -n 's/^Hardware[[:space:]]*:[[:space:]]*//p' /proc/cpuinfo | head -n 1)
fi
memory_kib=$(sed -n 's/^MemTotal:[[:space:]]*\([0-9][0-9]*\).*/\1/p' /proc/meminfo 2>/dev/null | head -n 1)
[ -n "$memory_kib" ] || memory_kib='unknown'

report="$workdir/report.md"
{
  printf '# royd reference-host report\n\n'
  printf 'This report records one host and the current runtime validation results. It is evidence for this exact environment only and should not be treated as a general compatibility claim.\n\n'
  printf '## Repository and image\n\n'
  printf -- '- royd commit: `%s`\n' "$royd_commit"
  printf -- '- Android baseline: `%s`\n' "${android_baseline:-unknown}"
  printf -- '- image: `%s`\n' "$image"
  printf -- '- runtime profile: `%s`\n\n' "$profile"
  printf '## Host\n\n'
  printf -- '- distribution: %s\n' "$os_release"
  printf -- '- kernel: `%s`\n' "$kernel"
  printf -- '- architecture: `%s`\n' "$architecture"
  printf -- '- CPU: %s\n' "${cpu_model:-unknown}"
  printf -- '- RAM: `%s KiB`\n' "$memory_kib"
  printf -- '- cgroup mode: `%s`\n' "$cgroup_mode"
  printf -- '- binderfs: `%s`\n' "$binderfs"
  printf -- '- GPU: `%s`\n' "$gpu_state"
  printf -- '- kernel config source: `%s`\n\n' "${kernel_config_path:-unavailable}"
  printf '### Relevant kernel configuration\n\n'
  printf '```text\n'
  cat "$workdir/kernel-config.out"
  printf '```\n\n'
  format_command_result 'Docker version' docker_version
  format_command_result 'Docker info' docker_info
  printf '## Runtime validation\n\n'
  format_command_result 'Single-instance smoke test' smoke
  format_command_result 'Two-instance smoke test' multi
  printf '## Interpretation\n\n'
  if [ "$(cat "$workdir/smoke.status")" -eq 0 ] && [ "$(cat "$workdir/multi.status")" -eq 0 ]; then
    printf 'Both repository runtime smoke tests passed on this host. This records a known-good result for the exact image, kernel, Docker configuration, and royd revision above.\n'
  else
    printf 'One or more runtime smoke tests failed. Review the captured output above before treating this host as compatible.\n'
  fi
} >"$report"

if [ "$output" = '-' ]; then
  cat "$report"
else
  mkdir -p "$(dirname -- "$output")"
  cp "$report" "$output"
  printf 'Wrote reference-host report to %s\n' "$output"
fi

if [ "$(cat "$workdir/smoke.status")" -ne 0 ] || [ "$(cat "$workdir/multi.status")" -ne 0 ]; then
  exit 1
fi
