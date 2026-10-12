#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
patch="$root/android/patches/android-15.0.0_r36/0033-vold-scope-container-fuse-aborts.patch"

[ -f "$patch" ] || { echo 'missing Android 15 vold FUSE-isolation patch' >&2; exit 1; }
[ "$(grep -c '^diff --git a/system/vold/Utils.cpp' "$patch")" -eq 1 ]
[ "$(grep -c '^diff --git ' "$patch")" -eq 1 ]
grep -F 'static bool IsRoydContainerWithoutSelinux() {' "$patch" >/dev/null
grep -F "roydContainer[0] == '1' && roydContainer[1] == '\\0'" "$patch" >/dev/null
grep -F 'is_selinux_enabled() <= 0;' "$patch" >/dev/null
grep -F 'ReadFileToString("/proc/self/mountinfo", &mountInfo)' "$patch" >/dev/null
grep -F 'fsType != "fuse" && !StartsWith(fsType, "fuse.")' "$patch" >/dev/null
grep -F 'connectionIds.insert(device.substr(colon + 1));' "$patch" >/dev/null
grep -F 'mountedConnectionIds.count(itEntry.path().filename().string()) == 0' "$patch" >/dev/null
grep -F 'Ignore FUSE connection outside this mount namespace' "$patch" >/dev/null

# The container gate filters only the host-global fusectl iteration. Visible connections and all
# non-container Android environments retain the stock iteration and abort control write.
grep -F 'for (const auto& itEntry : fs::directory_iterator(kFuseConnections, ec)) {' \
  "$patch" >/dev/null
if grep -Eq '^-.*(directory_iterator|writeStringToFile\("1", abortPath\)|virtiofs)' "$patch"; then
  echo 'vold FUSE-isolation patch changes the stock connection abort path' >&2
  exit 1
fi

printf '%s\n' 'Android 15 vold FUSE-isolation container contract passed'
