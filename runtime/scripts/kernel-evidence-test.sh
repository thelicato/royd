#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
probe="$script_dir/kernel-evidence.sh"
workdir=$(mktemp -d "${TMPDIR:-/tmp}/royd-kernel-evidence-test.XXXXXX")
trap 'rm -rf "$workdir"' EXIT HUP INT TERM
mkdir -p "$workdir/dri"

cat >"$workdir/config" <<'DATA'
CONFIG_ANDROID_BINDER_IPC=y
CONFIG_ANDROID_BINDERFS=y
CONFIG_NAMESPACES=y
CONFIG_CGROUPS=y
CONFIG_MEMCG=y
CONFIG_PSI=y
CONFIG_SECCOMP=y
CONFIG_SECCOMP_FILTER=y
CONFIG_USER_NS=y
CONFIG_DRM=m
DATA
cat >"$workdir/filesystems" <<'DATA'
nodev sysfs
nodev binder
DATA
printf '%s\n' 'cpuset cpu io memory pids' >"$workdir/cgroup.controllers"
printf '%s\n' 'some avg10=0.00 avg60=0.00 avg300=0.00 total=0' >"$workdir/memory.pressure"
printf '%s\n' 'lockdown,yama,apparmor,bpf' >"$workdir/lsm"
printf '%s\n' 1 >"$workdir/userns"
: >"$workdir/dri/renderD128"

common_env="ROYD_KERNEL_CONFIG_SOURCE=$workdir/config ROYD_KERNEL_PROC_FILESYSTEMS=$workdir/filesystems ROYD_KERNEL_CGROUP_CONTROLLERS=$workdir/cgroup.controllers ROYD_KERNEL_PSI_MEMORY=$workdir/memory.pressure ROYD_KERNEL_LSM_FILE=$workdir/lsm ROYD_KERNEL_DRI_DIR=$workdir/dri ROYD_KERNEL_USERNS_CLONE_FILE=$workdir/userns"
env $common_env "$probe" >"$workdir/pass.env"
grep -Fqx 'ROYD_KERNEL_EVIDENCE_FORMAT=1' "$workdir/pass.env"
grep -Fqx 'REQUIRED_CONFIG_STATUS=pass' "$workdir/pass.env"
grep -Fqx 'LIVE_BINDER_STATUS=pass' "$workdir/pass.env"
grep -Fqx 'BINDERFS_ADVERTISED=1' "$workdir/pass.env"
grep -Fqx 'CGROUP_V2=1' "$workdir/pass.env"
grep -Fqx 'CGROUP_CONTROLLERS=cpu,cpuset,io,memory,pids' "$workdir/pass.env"
grep -Fqx 'MEMORY_PSI=1' "$workdir/pass.env"
grep -Fqx 'LSM_ACTIVE=lockdown,yama,apparmor,bpf' "$workdir/pass.env"
grep -Fqx 'UNPRIVILEGED_USERNS_CLONE=1' "$workdir/pass.env"
grep -Fqx 'DRM_RENDER_NODE_COUNT=1' "$workdir/pass.env"
grep -Fqx 'KCONFIG_ANDROID_BINDER_IPC=y' "$workdir/pass.env"
grep -Fqx 'KCONFIG_ANDROID_BINDERFS=y' "$workdir/pass.env"
grep -Fqx 'KCONFIG_DRM=m' "$workdir/pass.env"

sed 's/^CONFIG_ANDROID_BINDERFS=y$/# CONFIG_ANDROID_BINDERFS is not set/' "$workdir/config" >"$workdir/config-disabled"
env $common_env ROYD_KERNEL_CONFIG_SOURCE="$workdir/config-disabled" "$probe" >"$workdir/disabled.env"
grep -Fqx 'REQUIRED_CONFIG_STATUS=fail' "$workdir/disabled.env"
grep -Fqx 'KCONFIG_ANDROID_BINDERFS=n' "$workdir/disabled.env"

env $common_env ROYD_KERNEL_CONFIG_SOURCE="$workdir/missing" "$probe" >"$workdir/unknown.env"
grep -Fqx 'CONFIG_SOURCE=unavailable' "$workdir/unknown.env"
grep -Fqx 'REQUIRED_CONFIG_STATUS=unknown' "$workdir/unknown.env"
grep -Fqx 'KCONFIG_ANDROID_BINDER_IPC=unknown' "$workdir/unknown.env"

output="$workdir/output/evidence.env"
env $common_env ROYD_KERNEL_EVIDENCE_OUTPUT="$output" "$probe" >"$workdir/write.out"
[ -f "$output" ]
grep -Fq "Wrote kernel evidence to $output" "$workdir/write.out"

printf '%s\n' 'Kernel evidence test passed'
