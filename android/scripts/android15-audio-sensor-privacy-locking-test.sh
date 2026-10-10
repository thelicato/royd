#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
patch="$root/android/patches/android-15.0.0_r36/0032-audio-policy-snapshot-sensor-privacy-under-lock.patch"

[ -f "$patch" ] || { echo 'missing Android 15 audio sensor-privacy locking patch' >&2; exit 1; }
[ "$(grep -c '^diff --git a/frameworks/av/services/audiopolicy/service/AudioPolicyService.cpp' "$patch")" -eq 1 ]
[ "$(grep -c '^diff --git ' "$patch")" -eq 1 ]
grep -F '+    sp<SensorPrivacyPolicy> sensorPrivacyPolicy;' "$patch" >/dev/null
grep -F '+        audio_utils::lock_guard _l(mMutex);' "$patch" >/dev/null
grep -F '+        sensorPrivacyPolicy = mSensorPrivacyPolicy;' "$patch" >/dev/null
grep -F '+    sensorPrivacyPolicy->registerSelf();' "$patch" >/dev/null
grep -F 'audio_utils::lock_guard _l(mMutex);' "$patch" >/dev/null
grep -F 'updateUidStates_l();' "$patch" >/dev/null
grep -F -- '-    mSensorPrivacyPolicy->registerSelf();' "$patch" >/dev/null

# The guarded member is copied while the service mutex is held. Binder registration must occur
# after that scope ends, before the stock update path reacquires the same mutex.
copy_line=$(grep -n '^+        sensorPrivacyPolicy = mSensorPrivacyPolicy;' "$patch" | cut -d: -f1)
register_line=$(grep -n '^+    sensorPrivacyPolicy->registerSelf();' "$patch" | cut -d: -f1)
update_lock_line=$(grep -n '^     audio_utils::lock_guard _l(mMutex);' "$patch" | cut -d: -f1)
[ "$copy_line" -lt "$register_line" ] && [ "$register_line" -lt "$update_lock_line" ] || {
  echo 'audio sensor-privacy registration does not remain outside the service lock' >&2
  exit 1
}
if grep -Eq '^-.*(updateUidStates_l|mMutex)' "$patch"; then
  echo 'audio sensor-privacy locking patch changes the stock update or mutex path' >&2
  exit 1
fi

printf '%s\n' 'Android 15 audio sensor-privacy locking contract passed'
