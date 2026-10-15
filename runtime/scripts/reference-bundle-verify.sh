#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
# shellcheck disable=SC1091
. "$script_dir/runtime-result-lib.sh"
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
[ "$(get ROYD_REFERENCE_BUNDLE_FORMAT)" = 4 ] || { printf '%s\n' 'error: unsupported reference bundle format' >&2; exit 1; }
[ "$(get RESULT_STATUS)" = pass ] || { printf '%s\n' 'error: reference bundle did not pass qualification' >&2; exit 1; }
for stage in KERNEL_STATUS HOST_STATUS IMAGE_STATUS QUALIFICATION_STATUS REFERENCE_STATUS RUNTIME_LOG_STATUS RUNTIME_EVIDENCE_STATUS; do
  [ "$(get "$stage")" = pass ] || { printf 'error: required stage is not pass: %s\n' "$stage" >&2; exit 1; }
done
case "$(get SCRCPY_REQUIRED)" in
  0) ;;
  1)
    [ "$(get SCRCPY_STATUS)" = pass ] || { printf '%s\n' 'error: required scrcpy stage is not pass' >&2; exit 1; }
    [ -f "$bundle/scrcpy/manifest.env" ] || { printf '%s\n' 'error: scrcpy manifest is missing' >&2; exit 1; }
    scrcpy_get() { sed -n "s/^$1=//p" "$bundle/scrcpy/manifest.env" | tail -n 1; }
    [ "$(scrcpy_get ROYD_SCRCPY_EVIDENCE_FORMAT)" = 2 ] || { printf '%s\n' 'error: scrcpy evidence format is stale' >&2; exit 1; }
    [ "$(scrcpy_get RESULT_STATUS)" = pass ] || { printf '%s\n' 'error: scrcpy evidence did not pass' >&2; exit 1; }
    [ "$(scrcpy_get POST_RUNTIME_STATUS)" = pass ] || { printf '%s\n' 'error: scrcpy post-workload runtime assertions did not pass' >&2; exit 1; }
    [ -f "$bundle/scrcpy/post-runtime.log" ] || { printf '%s\n' 'error: scrcpy post-workload runtime log is missing' >&2; exit 1; }
    [ -s "$bundle/scrcpy/scrcpy.mp4" ] || { printf '%s\n' 'error: scrcpy recording is missing or empty' >&2; exit 1; }
    scrcpy_bytes=$(wc -c <"$bundle/scrcpy/scrcpy.mp4" | tr -d ' ')
    scrcpy_sha256=$(sha256sum "$bundle/scrcpy/scrcpy.mp4" | awk '{print $1}')
    [ "$(scrcpy_get RECORDING_BYTES)" = "$scrcpy_bytes" ] || { printf '%s\n' 'error: scrcpy recording size does not match its manifest' >&2; exit 1; }
    [ "$(scrcpy_get RECORDING_SHA256)" = "$scrcpy_sha256" ] || { printf '%s\n' 'error: scrcpy recording digest does not match its manifest' >&2; exit 1; }
    ;;
  *) printf '%s\n' 'error: invalid SCRCPY_REQUIRED value' >&2; exit 1 ;;
esac

android_version=$(get ANDROID_VERSION)
image_profile=$(get IMAGE_PROFILE)
security_mode=$(get SECURITY_MODE)
expected_policy=$(ROYD_ANDROID_VERSION="$android_version" "$repo_root/android/scripts/profile-policy.sh" "$image_profile")
expected_policy_sha=$(ROYD_ANDROID_VERSION="$android_version" "$repo_root/android/scripts/profile-packages.sh" "$image_profile" | sha256sum | awk '{print $1}')
expected_security=$("$script_dir/security-profile.sh" "$security_mode" id)
expected_security_sha=$("$script_dir/security-profile.sh" "$security_mode" digest)
resource_profile=$(get RESOURCE_PROFILE)
"$script_dir/resource-profile.sh" "$resource_profile" >/dev/null
[ "$(get PROFILE_POLICY)" = "$expected_policy" ] || { printf '%s\n' 'error: bundle image-profile policy is stale' >&2; exit 1; }
[ "$(get PROFILE_POLICY_SHA256)" = "$expected_policy_sha" ] || { printf '%s\n' 'error: bundle image-profile policy digest is stale' >&2; exit 1; }
[ "$(get SECURITY_PROFILE)" = "$expected_security" ] || { printf '%s\n' 'error: bundle security profile is stale' >&2; exit 1; }
[ "$(get SECURITY_PROFILE_SHA256)" = "$expected_security_sha" ] || { printf '%s\n' 'error: bundle security profile digest is stale' >&2; exit 1; }

[ -f "$bundle/kernel.env" ] || { printf '%s\n' 'error: kernel.env is missing' >&2; exit 1; }
kernel_get() { sed -n "s/^$1=//p" "$bundle/kernel.env" | tail -n 1; }
[ "$(kernel_get ROYD_KERNEL_EVIDENCE_FORMAT)" = 1 ] || { printf '%s\n' 'error: kernel evidence format is stale' >&2; exit 1; }
expected_kernel_contract_sha=$(sha256sum "$repo_root/runtime/kernel/config-contract.tsv" | awk '{print $1}')
[ "$(kernel_get CONFIG_CONTRACT_SHA256)" = "$expected_kernel_contract_sha" ] || { printf '%s\n' 'error: kernel config contract is stale' >&2; exit 1; }

[ -f "$bundle/runtime-result.env" ] || { printf '%s\n' 'error: runtime-result.env is missing' >&2; exit 1; }
[ -f "$bundle/runtime-qualification.log" ] || { printf '%s\n' 'error: runtime-qualification.log is missing' >&2; exit 1; }
[ -f "$bundle/runtime-evidence/container-inspect.json" ] || { printf '%s\n' 'error: runtime container inspect evidence is missing' >&2; exit 1; }
[ -f "$bundle/runtime-evidence/container.log" ] || { printf '%s\n' 'error: runtime container log evidence is missing' >&2; exit 1; }
[ -f "$bundle/runtime-evidence/state.txt" ] || { printf '%s\n' 'error: runtime container state evidence is missing' >&2; exit 1; }
[ "$(runtime_result_get "$bundle/runtime-result.env" RESULT_FORMAT || true)" = 4 ] || { printf '%s\n' 'error: runtime result format is stale' >&2; exit 1; }
[ "$(runtime_result_get "$bundle/runtime-result.env" RESOURCE_PROFILE || true)" = "$resource_profile" ] || { printf '%s\n' 'error: runtime resource profile is stale' >&2; exit 1; }
[ "$(runtime_result_get "$bundle/runtime-result.env" CONTAINER_EVIDENCE_STATUS || true)" = pass ] || { printf '%s\n' 'error: runtime container evidence did not pass' >&2; exit 1; }
printf 'Reference-host evidence bundle verified: %s\n' "$bundle"
