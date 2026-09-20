#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
probe="$script_dir/rootless-probe.sh"
workdir=$(mktemp -d "${TMPDIR:-/tmp}/royd-rootless-test.XXXXXX")
trap 'rm -rf "$workdir"' EXIT HUP INT TERM
mkdir -p "$workdir/bin"

cat >"$workdir/filesystems" <<'DATA'
nodev sysfs
nodev binder
DATA
: >"$workdir/cgroup.controllers"
printf '%s\n' 'tester:100000:65536' >"$workdir/subuid"
printf '%s\n' 'tester:200000:65536' >"$workdir/subgid"

for command in mount umount newuidmap newgidmap; do
  cat >"$workdir/bin/$command" <<'SH'
#!/bin/sh
exit 0
SH
  chmod +x "$workdir/bin/$command"
done
cat >"$workdir/bin/unshare" <<'SH'
#!/bin/sh
exit "${ROYD_TEST_UNSHARE_EXIT:-0}"
SH
chmod +x "$workdir/bin/unshare"

common_env="PATH=$workdir/bin:$PATH ROYD_ROOTLESS_PROC_FILESYSTEMS=$workdir/filesystems ROYD_ROOTLESS_CGROUP_CONTROLLERS=$workdir/cgroup.controllers ROYD_ROOTLESS_SUBUID_FILE=$workdir/subuid ROYD_ROOTLESS_SUBGID_FILE=$workdir/subgid ROYD_ROOTLESS_UID=1000 ROYD_ROOTLESS_USER=tester"

env $common_env "$probe" >"$workdir/pass.out"
grep -Fq 'binderfs advertised by kernel' "$workdir/pass.out"
grep -Fq 'at least 65536 subordinate UIDs configured for tester' "$workdir/pass.out"
grep -Fq 'unprivileged user namespace can mount a private binderfs instance with binder-control' "$workdir/pass.out"
grep -Fq 'Kernel and account prerequisites passed.' "$workdir/pass.out"

if env $common_env ROYD_TEST_UNSHARE_EXIT=1 "$probe" >"$workdir/fail.out" 2>&1; then
  printf '%s\n' 'error: rootless probe unexpectedly passed when user-namespace binderfs mount failed' >&2
  exit 1
fi
grep -Fq 'direct unprivileged user-namespace binderfs probe failed; engine-specific user-namespace policy may differ' "$workdir/fail.out"
grep -Fq 'Direct rootless feasibility is unverified on this host.' "$workdir/fail.out"

printf '%s\n' 'Rootless probe test passed'
