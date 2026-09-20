#!/bin/sh
set -eu

proc_filesystems=${ROYD_ROOTLESS_PROC_FILESYSTEMS:-/proc/filesystems}
cgroup_controllers=${ROYD_ROOTLESS_CGROUP_CONTROLLERS:-/sys/fs/cgroup/cgroup.controllers}
subuid_file=${ROYD_ROOTLESS_SUBUID_FILE:-/etc/subuid}
subgid_file=${ROYD_ROOTLESS_SUBGID_FILE:-/etc/subgid}
probe_uid=${ROYD_ROOTLESS_UID:-$(id -u)}
probe_user=${ROYD_ROOTLESS_USER:-$(id -un 2>/dev/null || printf '%s' "$probe_uid")}

errors=0
warnings=0

action_ok() {
  printf 'ok      %s\n' "$*"
}

action_warn() {
  warnings=$((warnings + 1))
  printf 'warning %s\n' "$*"
}

action_fail() {
  errors=$((errors + 1))
  printf 'error   %s\n' "$*"
}

has_subordinate_range() {
  file=$1
  user=$2
  [ -r "$file" ] || return 1
  awk -F: -v user="$user" '$1 == user && $3 >= 65536 { found=1 } END { exit !found }' "$file"
}

if [ "$(uname -s)" = Linux ]; then
  action_ok "Linux host kernel: $(uname -r)"
else
  action_fail 'rootless royd research applies only to Linux hosts'
fi

if [ "$probe_uid" = 0 ]; then
  action_warn 'probe is running as UID 0; user-namespace checks do not represent an ordinary rootless account'
else
  action_ok "probe account is unprivileged: $probe_user (uid $probe_uid)"
fi

if awk '$NF == "binder" { found=1 } END { exit !found }' "$proc_filesystems" 2>/dev/null; then
  action_ok 'binderfs advertised by kernel'
else
  action_fail 'binderfs is not advertised by the host kernel'
fi

for command in unshare mount umount newuidmap newgidmap; do
  if command -v "$command" >/dev/null 2>&1; then
    action_ok "$command command found"
  else
    action_fail "$command command not found"
  fi
done

if has_subordinate_range "$subuid_file" "$probe_user"; then
  action_ok "at least 65536 subordinate UIDs configured for $probe_user"
else
  action_fail "no subordinate UID range of at least 65536 found for $probe_user in $subuid_file"
fi

if has_subordinate_range "$subgid_file" "$probe_user"; then
  action_ok "at least 65536 subordinate GIDs configured for $probe_user"
else
  action_fail "no subordinate GID range of at least 65536 found for $probe_user in $subgid_file"
fi

if [ -r "$cgroup_controllers" ]; then
  action_ok 'cgroup v2 detected'
else
  action_warn 'cgroup v2 not detected; rootless memory and process limits may be unavailable or incomplete'
fi

namespace_probe_ready=1
for command in unshare mount umount; do
  command -v "$command" >/dev/null 2>&1 || namespace_probe_ready=0
done

if [ "$namespace_probe_ready" = 1 ] && awk '$NF == "binder" { found=1 } END { exit !found }' "$proc_filesystems" 2>/dev/null; then
  workdir=$(mktemp -d "${TMPDIR:-/tmp}/royd-rootless.XXXXXX")
  trap 'rmdir "$workdir/binderfs" "$workdir" 2>/dev/null || true' EXIT HUP INT TERM
  mkdir "$workdir/binderfs"
  if unshare --user --map-root-user --mount --ipc sh -eu -c '
      mountpoint=$1
      mount -t binder binder "$mountpoint"
      test -c "$mountpoint/binder-control"
      umount "$mountpoint"
    ' sh "$workdir/binderfs" >/dev/null 2>&1; then
    action_ok 'unprivileged user namespace can mount a private binderfs instance with binder-control'
  else
    action_fail 'direct unprivileged user-namespace binderfs probe failed; engine-specific user-namespace policy may differ'
  fi
  rmdir "$workdir/binderfs" "$workdir" 2>/dev/null || true
  trap - EXIT HUP INT TERM
fi

render_node=
for node in /dev/dri/renderD*; do
  if [ -e "$node" ]; then
    render_node=$node
    break
  fi
done
if [ -n "$render_node" ]; then
  if [ -r "$render_node" ] && [ -w "$render_node" ]; then
    action_ok "DRM render node is directly accessible to the rootless account: $render_node"
  else
    action_warn "DRM render node exists but is not directly readable and writable by the rootless account: $render_node"
  fi
else
  action_ok 'no DRM render node required for the software graphics rootless candidate'
fi

printf '\nRootless candidate summary: %s error(s), %s warning(s)\n' "$errors" "$warnings"
if [ "$errors" -eq 0 ]; then
  printf '%s\n' 'Kernel and account prerequisites passed. Android rootless boot remains unqualified until a real royd image passes the runtime gates.'
else
  printf '%s\n' 'Direct rootless feasibility is unverified on this host. Fix hard prerequisites or investigate engine-specific user-namespace policy before attempting qualification.'
fi
[ "$errors" -eq 0 ]
