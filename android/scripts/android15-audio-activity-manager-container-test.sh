#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
patch="$root/android/patches/android-15.0.0_r36/0030-audio-policy-defer-container-activity-manager.patch"

[ -f "$patch" ] || { echo 'missing Android 15 audio ActivityManager deferral patch' >&2; exit 1; }
[ "$(grep -c '^diff --git a/frameworks/av/services/audiopolicy/service/AudioPolicyService.cpp' "$patch")" -eq 1 ]
[ "$(grep -c '^diff --git ' "$patch")" -eq 1 ]
grep -F 'bool shouldDeferRoydAudioUidObserver() {' "$patch" >/dev/null
grep -F 'strcmp(roydContainer, "1") != 0' "$patch" >/dev/null
grep -F 'access("/sys/fs/selinux/enforce", F_OK) == 0' "$patch" >/dev/null
grep -F 'defaultServiceManager()->checkService(String16("activity")) == nullptr' "$patch" >/dev/null
grep -F 'if (shouldDeferRoydAudioUidObserver()) {' "$patch" >/dev/null
grep -F 'ROYD: ActivityManager is not published; deferring audio UID observer' "$patch" >/dev/null

# The container-only pre-check may defer registration, but the stock observer, death handling and
# conservative fallback must remain unchanged for registration retries and all other environments.
grep -F 'status_t res = mAm.linkToDeath(this);' "$patch" >/dev/null
grep -F 'mAm.registerUidObserver(this, ActivityManager::UID_OBSERVER_GONE' "$patch" >/dev/null
if grep -Eq '^-.*(linkToDeath|registerUidObserver|mObserverRegistered|checkRegistered|PROCESS_STATE_TOP)' "$patch"; then
  echo 'audio ActivityManager patch changes the stock observer or fallback path' >&2
  exit 1
fi

printf '%s\n' 'Android 15 audio ActivityManager deferral contract passed'
