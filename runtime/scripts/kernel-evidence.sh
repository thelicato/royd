#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
contract=${ROYD_KERNEL_CONFIG_CONTRACT:-$repo_root/runtime/kernel/config-contract.tsv}
output=${ROYD_KERNEL_EVIDENCE_OUTPUT:--}
proc_filesystems=${ROYD_KERNEL_PROC_FILESYSTEMS:-/proc/filesystems}
cgroup_controllers=${ROYD_KERNEL_CGROUP_CONTROLLERS:-/sys/fs/cgroup/cgroup.controllers}
psi_memory=${ROYD_KERNEL_PSI_MEMORY:-/proc/pressure/memory}
lsm_file=${ROYD_KERNEL_LSM_FILE:-/sys/kernel/security/lsm}
dri_dir=${ROYD_KERNEL_DRI_DIR:-/dev/dri}
userns_clone_file=${ROYD_KERNEL_USERNS_CLONE_FILE:-/proc/sys/kernel/unprivileged_userns_clone}
explicit_config=${ROYD_KERNEL_CONFIG_SOURCE:-}

[ "$(uname -s)" = Linux ] || {
  printf '%s\n' 'error: kernel evidence is available only on Linux hosts' >&2
  exit 1
}
[ -r "$contract" ] || {
  printf 'error: kernel config contract is not readable: %s\n' "$contract" >&2
  exit 1
}
command -v sha256sum >/dev/null 2>&1 || {
  printf '%s\n' 'error: sha256sum is required to record kernel evidence' >&2
  exit 1
}

first_existing_kernel_config() {
  if [ -n "$explicit_config" ]; then
    [ -r "$explicit_config" ] && printf '%s\n' "$explicit_config"
    return
  fi
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
    *.gz)
      if command -v gzip >/dev/null 2>&1; then
        gzip -cd "$path"
      elif command -v zcat >/dev/null 2>&1; then
        zcat "$path"
      else
        return 1
      fi
      ;;
    *) cat "$path" ;;
  esac
}

config_value() {
  option=$1
  file=$2
  value=$(sed -n "s/^$option=//p" "$file" | tail -n 1)
  if [ -n "$value" ]; then
    printf '%s\n' "$value"
    return
  fi
  if grep -Fqx "# $option is not set" "$file"; then
    printf '%s\n' n
  else
    printf '%s\n' unknown
  fi
}

normalise_words() {
  tr '[:space:]' '\n' | sed '/^$/d' | LC_ALL=C sort -u | paste -sd, -
}

workdir=$(mktemp -d "${TMPDIR:-/tmp}/royd-kernel-evidence.XXXXXX")
cleanup() { rm -rf "$workdir"; }
trap cleanup EXIT HUP INT TERM
config_file="$workdir/kernel.config"
config_source=unavailable
config_source_sha256=unavailable
if config_source=$(first_existing_kernel_config); then
  if read_kernel_config "$config_source" >"$config_file" 2>/dev/null && [ -s "$config_file" ]; then
    config_source_sha256=$(sha256sum "$config_file" | awk '{print $1}')
  else
    config_source=unavailable
    : >"$config_file"
  fi
else
  config_source=unavailable
  : >"$config_file"
fi

contract_sha256=$(sha256sum "$contract" | awk '{print $1}')
if awk '$NF == "binder" { found=1 } END { exit !found }' "$proc_filesystems" 2>/dev/null; then binderfs_advertised=1; else binderfs_advertised=0; fi
if [ -r "$cgroup_controllers" ]; then
  cgroup_v2=1
  controllers=$(normalise_words <"$cgroup_controllers")
  [ -n "$controllers" ] || controllers=none
else
  cgroup_v2=0
  controllers=unavailable
fi
if [ -r "$psi_memory" ]; then memory_psi=1; else memory_psi=0; fi
if [ -r "$lsm_file" ]; then
  lsm_active=$(tr -d '\n' <"$lsm_file" | tr ' ' '_')
  [ -n "$lsm_active" ] || lsm_active=none
else
  lsm_active=unavailable
fi
if [ -r "$userns_clone_file" ]; then
  unprivileged_userns_clone=$(tr -d '[:space:]' <"$userns_clone_file")
  [ -n "$unprivileged_userns_clone" ] || unprivileged_userns_clone=unavailable
else
  unprivileged_userns_clone=unavailable
fi

render_nodes=none
render_node_count=0
if [ -d "$dri_dir" ]; then
  nodes=''
  for node in "$dri_dir"/renderD*; do
    [ -e "$node" ] || continue
    render_node_count=$((render_node_count + 1))
    if [ -n "$nodes" ]; then nodes="$nodes,$node"; else nodes=$node; fi
  done
  [ -n "$nodes" ] && render_nodes=$nodes
fi

required_total=0
required_enabled=0
required_disabled=0
required_unknown=0
config_lines="$workdir/config-lines"
: >"$config_lines"
while IFS="$(printf '\t')" read -r scope level option description; do
  case "$scope" in ''|'#'*) continue ;; esac
  case "$level" in required|preferred|recorded|path-specific) ;; *) printf 'error: invalid kernel config level in contract: %s\n' "$level" >&2; exit 1 ;; esac
  case "$option" in CONFIG_*) ;; *) printf 'error: invalid kernel config option in contract: %s\n' "$option" >&2; exit 1 ;; esac
  value=unknown
  if [ "$config_source" != unavailable ]; then value=$(config_value "$option" "$config_file"); fi
  printf 'KCONFIG_%s=%s\n' "${option#CONFIG_}" "$value" >>"$config_lines"
  if [ "$level" = required ]; then
    required_total=$((required_total + 1))
    case "$value" in
      y|m) required_enabled=$((required_enabled + 1)) ;;
      n) required_disabled=$((required_disabled + 1)) ;;
      *) required_unknown=$((required_unknown + 1)) ;;
    esac
  fi
done <"$contract"

if [ "$required_disabled" -gt 0 ]; then
  required_config_status=fail
elif [ "$required_unknown" -gt 0 ] || [ "$required_enabled" -ne "$required_total" ]; then
  required_config_status=unknown
else
  required_config_status=pass
fi
if [ "$binderfs_advertised" -eq 1 ]; then live_binder_status=pass; else live_binder_status=fail; fi

report="$workdir/evidence.env"
{
  printf 'ROYD_KERNEL_EVIDENCE_FORMAT=1\n'
  printf 'CAPTURED_AT=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'KERNEL_RELEASE=%s\n' "$(uname -r)"
  printf 'ARCH=%s\n' "$(uname -m)"
  printf 'CONFIG_CONTRACT_SHA256=%s\n' "$contract_sha256"
  printf 'CONFIG_SOURCE=%s\n' "$config_source"
  printf 'CONFIG_SOURCE_SHA256=%s\n' "$config_source_sha256"
  printf 'REQUIRED_CONFIG_STATUS=%s\n' "$required_config_status"
  printf 'LIVE_BINDER_STATUS=%s\n' "$live_binder_status"
  printf 'BINDERFS_ADVERTISED=%s\n' "$binderfs_advertised"
  printf 'CGROUP_V2=%s\n' "$cgroup_v2"
  printf 'CGROUP_CONTROLLERS=%s\n' "$controllers"
  printf 'MEMORY_PSI=%s\n' "$memory_psi"
  printf 'LSM_ACTIVE=%s\n' "$lsm_active"
  printf 'UNPRIVILEGED_USERNS_CLONE=%s\n' "$unprivileged_userns_clone"
  printf 'DRM_RENDER_NODE_COUNT=%s\n' "$render_node_count"
  printf 'DRM_RENDER_NODES=%s\n' "$render_nodes"
  cat "$config_lines"
} >"$report"

if [ "$output" = - ]; then
  cat "$report"
else
  mkdir -p "$(dirname -- "$output")"
  cp "$report" "$output"
  printf 'Wrote kernel evidence to %s\n' "$output"
fi
