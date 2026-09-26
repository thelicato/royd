#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
patch="$root/android/patches/android-15.0.0_r36/0001-init-support-royd-container-selinux-disabled.patch"
entrypoint="$root/runtime/rootfs/royd-entrypoint"
args="$root/runtime/scripts/container-args.sh"
vendor_init="$root/android/royd/vendor/royd/init.royd.rc"

[ -f "$patch" ] || { echo 'missing Android 15 royd container init patch' >&2; exit 1; }
grep -F 'IsRoydContainerWithoutSelinux' "$patch" >/dev/null
grep -F 'is_selinux_enabled() <= 0' "$patch" >/dev/null
grep -F 'scon.clear();' "$patch" >/dev/null
grep -F 'void InitializeSubcontext() {' "$patch" >/dev/null
grep -F 'return;' "$patch" >/dev/null
grep -F 'export ROYD_CONTAINER=1' "$entrypoint" >/dev/null
grep -F 'exec /init second_stage' "$entrypoint" >/dev/null
awk '
  $0 == "on late-fs" {
    getline
    if ($0 == "    trigger nonencrypted") found++
  }
  END { exit found == 1 ? 0 : 1 }
' "$vendor_init"
[ "$("$args")" = '--tmpfs=/dev/socket:rw,nosuid,nodev,noexec,mode=0755' ] || {
  echo 'unexpected container runtime arguments' >&2
  exit 1
}
# Guard normal Android behaviour: bypasses must remain gated by both the royd marker and disabled SELinux.
[ "$(grep -c 'ROYD_CONTAINER' "$patch")" -ge 2 ]
[ "$(grep -c 'is_selinux_enabled() <= 0' "$patch")" -eq 2 ]

echo 'Android 15 container init contract passed'
