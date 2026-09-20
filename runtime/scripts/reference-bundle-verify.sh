#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
bundle=${1:-}
[ -n "$bundle" ] || { printf '%s\n' 'usage: reference-bundle-verify.sh BUNDLE_DIR' >&2; exit 2; }
[ -d "$bundle" ] || { printf 'error: bundle directory not found: %s\n' "$bundle" >&2; exit 2; }
[ -f "$bundle/manifest.env" ] || { printf '%s\n' 'error: manifest.env is missing' >&2; exit 1; }
[ -f "$bundle/SHA256SUMS" ] || { printf '%s\n' 'error: SHA256SUMS is missing' >&2; exit 1; }

(
  cd "$bundle"
  sha256sum -c SHA256SUMS
) >/dev/null

get() { sed -n "s/^$1=//p" "$bundle/manifest.env" | tail -n 1; }
[ "$(get ROYD_REFERENCE_BUNDLE_FORMAT)" = 1 ] || { printf '%s\n' 'error: unsupported reference bundle format' >&2; exit 1; }
[ "$(get RESULT_STATUS)" = pass ] || { printf '%s\n' 'error: reference bundle did not pass qualification' >&2; exit 1; }
for stage in HOST_STATUS IMAGE_STATUS QUALIFICATION_STATUS REFERENCE_STATUS; do
  [ "$(get "$stage")" = pass ] || { printf 'error: required stage is not pass: %s\n' "$stage" >&2; exit 1; }
done

android_version=$(get ANDROID_VERSION)
image_profile=$(get IMAGE_PROFILE)
security_mode=$(get SECURITY_MODE)
expected_policy=$(ROYD_ANDROID_VERSION="$android_version" "$repo_root/android/scripts/profile-policy.sh" "$image_profile")
expected_policy_sha=$(ROYD_ANDROID_VERSION="$android_version" "$repo_root/android/scripts/profile-packages.sh" "$image_profile" | sha256sum | awk '{print $1}')
expected_security=$("$script_dir/security-profile.sh" "$security_mode" id)
expected_security_sha=$("$script_dir/security-profile.sh" "$security_mode" digest)
[ "$(get PROFILE_POLICY)" = "$expected_policy" ] || { printf '%s\n' 'error: bundle image-profile policy is stale' >&2; exit 1; }
[ "$(get PROFILE_POLICY_SHA256)" = "$expected_policy_sha" ] || { printf '%s\n' 'error: bundle image-profile policy digest is stale' >&2; exit 1; }
[ "$(get SECURITY_PROFILE)" = "$expected_security" ] || { printf '%s\n' 'error: bundle security profile is stale' >&2; exit 1; }
[ "$(get SECURITY_PROFILE_SHA256)" = "$expected_security_sha" ] || { printf '%s\n' 'error: bundle security profile digest is stale' >&2; exit 1; }

[ -f "$bundle/runtime-result.env" ] || { printf '%s\n' 'error: runtime-result.env is missing' >&2; exit 1; }
printf 'Reference-host evidence bundle verified: %s\n' "$bundle"
