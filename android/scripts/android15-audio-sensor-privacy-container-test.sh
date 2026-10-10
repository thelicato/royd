#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
patch="$root/android/patches/android-15.0.0_r36/0031-audio-policy-defer-container-sensor-privacy.patch"

[ -f "$patch" ] || { echo 'missing Android 15 audio sensor-privacy deferral patch' >&2; exit 1; }
[ "$(grep -c '^diff --git a/frameworks/av/services/audiopolicy/service/AudioPolicyService' "$patch")" -eq 2 ]
[ "$(grep -c '^diff --git ' "$patch")" -eq 2 ]
grep -F 'bool shouldDeferRoydSensorPrivacyObserver() {' "$patch" >/dev/null
grep -F 'strcmp(roydContainer, "1") != 0' "$patch" >/dev/null
grep -F 'access("/sys/fs/selinux/enforce", F_OK) == 0' "$patch" >/dev/null
grep -F 'checkService(String16("sensor_privacy")) == nullptr' "$patch" >/dev/null
grep -F 'ROYD: sensor privacy service is not published; deferring audio privacy' "$patch" >/dev/null
grep -F '+    mSensorPrivacyPolicy->registerSelf();' "$patch" >/dev/null
grep -F 'std::atomic_bool mObserverRegistered = false;' "$patch" >/dev/null
grep -F 'mObserverRegistered.compare_exchange_strong(expected, true)' "$patch" >/dev/null
grep -F 'if (!mObserverRegistered.exchange(false)) {' "$patch" >/dev/null

# The initial container-only pre-check may defer registration. A later policy evaluation must
# retry it, and the stock state query, listener operations and disabled fallback remain intact.
grep -F 'mSensorPrivacyEnabled = spm.isSensorPrivacyEnabled();' "$patch" >/dev/null
grep -F 'spm.addSensorPrivacyListener(this);' "$patch" >/dev/null
grep -F 'spm.removeSensorPrivacyListener(this);' "$patch" >/dev/null
if grep -Eq '^-.*(isSensorPrivacyEnabled|addSensorPrivacyListener|removeSensorPrivacyListener|mSensorPrivacyEnabled)' "$patch"; then
  echo 'audio sensor-privacy patch changes the stock state or listener operations' >&2
  exit 1
fi

printf '%s\n' 'Android 15 audio sensor-privacy deferral contract passed'
