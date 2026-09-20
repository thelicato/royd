#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
# shellcheck disable=SC1091
. "$repo_root/android/baseline.env"
# shellcheck disable=SC1091
. "$script_dir/runtime-result-lib.sh"

android_version=${ROYD_ANDROID_VERSION:-$ROYD_DEFAULT_ANDROID_VERSION}
version_env="$repo_root/android/versions/$android_version.env"
[ -f "$version_env" ] || { printf 'error: unsupported Android version: %s\n' "$android_version" >&2; exit 2; }
# shellcheck disable=SC1090
. "$version_env"
arch=${ROYD_QUALIFY_ARCH:-x86_64}
image_profile=${ROYD_ANDROID_PROFILE:-standard}
image_profile=$("$repo_root/android/scripts/profile.sh" "$image_profile")
hal_profile=${ROYD_HAL_PROFILE:-graphical}
hal_profile=$("$repo_root/android/scripts/hal-profile.sh" "$hal_profile")
security_mode=${ROYD_SECURITY_MODE:-privileged}
security_profile=$("$script_dir/security-profile.sh" "$security_mode" id)
security_profile_sha256=$("$script_dir/security-profile.sh" "$security_mode" digest)
graphics_backend=${ROYD_GRAPHICS_BACKEND:-software}
graphics_backend=$(ROYD_GRAPHICS_ARCH="$arch" "$repo_root/android/scripts/graphics-backend.sh" "$graphics_backend" "$arch")
profile_policy=$(ROYD_ANDROID_VERSION="$android_version" "$repo_root/android/scripts/profile-policy.sh" "$image_profile")
profile_policy_sha256=$(ROYD_ANDROID_VERSION="$android_version" "$repo_root/android/scripts/profile-packages.sh" "$image_profile" | sha256sum | awk '{print $1}')
runtime_profile=${ROYD_PROFILE:-$(ROYD_HAL_PROFILE="$hal_profile" "$script_dir/default-runtime-profile.sh")}
image=${ROYD_IMAGE:-$(ROYD_HAL_PROFILE="$hal_profile" ROYD_GRAPHICS_BACKEND="$graphics_backend" "$script_dir/default-image.sh" "$image_profile" "$arch")}
work_root=${ROYD_WORK_DIR:-$repo_root/.work}
output=${ROYD_REFERENCE_BUNDLE_OUTPUT:-$work_root/reference-hosts/$android_version-$arch-$image_profile-$hal_profile-$graphics_backend-$security_mode}
include_memory=${ROYD_REFERENCE_INCLUDE_MEMORY:-1}
include_capability_sweep=${ROYD_REFERENCE_INCLUDE_CAPABILITY_SWEEP:-0}
replace=${ROYD_REFERENCE_REPLACE:-0}

host_runner=${ROYD_REFERENCE_HOST_RUNNER:-$script_dir/host-check.sh}
image_runner=${ROYD_REFERENCE_IMAGE_RUNNER:-$script_dir/image-inspect.sh}
qualification_runner=${ROYD_REFERENCE_QUALIFICATION_RUNNER:-$script_dir/qualification.sh}
reference_runner=${ROYD_REFERENCE_REPORT_RUNNER:-$script_dir/reference-report.sh}
memory_runner=${ROYD_REFERENCE_MEMORY_RUNNER:-$script_dir/memory-sweep.sh}
capability_runner=${ROYD_REFERENCE_CAPABILITY_RUNNER:-$script_dir/security-capability-sweep.sh}

case "$arch" in x86_64|arm64) ;; *) printf 'error: unsupported reference architecture: %s\n' "$arch" >&2; exit 2 ;; esac
case "$include_memory:$include_capability_sweep:$replace" in
  [01]:[01]:[01]) ;;
  *) printf '%s\n' 'error: ROYD_REFERENCE_INCLUDE_MEMORY, ROYD_REFERENCE_INCLUDE_CAPABILITY_SWEEP, and ROYD_REFERENCE_REPLACE must be 0 or 1' >&2; exit 2 ;;
esac
if [ "$include_capability_sweep" -eq 1 ] && [ "$security_mode" != experimental ]; then
  printf '%s\n' 'error: capability sweep is valid only with ROYD_SECURITY_MODE=experimental' >&2
  exit 2
fi

if [ -e "$output" ]; then
  if [ "$replace" -eq 1 ]; then rm -rf "$output"; else printf 'error: reference bundle already exists: %s\n' "$output" >&2; exit 2; fi
fi
mkdir -p "$output"
log="$output/orchestration.log"
: > "$log"
started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
overall=pass

run_stage() {
  name=$1
  shift
  printf '==> %s\n' "$name" | tee -a "$log"
  set +e
  "$@" >"$output/$name.log" 2>&1
  code=$?
  set -e
  if [ "$code" -eq 0 ]; then
    eval "${name}_status=pass"
  else
    eval "${name}_status=fail"
    overall=fail
  fi
  printf '<== %s: %s\n' "$name" "$(eval "printf '%s' \"\$${name}_status\"")" | tee -a "$log"
}

host_status=not-run
image_status=not-run
qualification_status=not-run
reference_status=not-run
memory_status=not-run
capability_status=not-run

run_stage host env ROYD_SECURITY_MODE="$security_mode" ROYD_GRAPHICS_BACKEND="$graphics_backend" "$host_runner"
run_stage image env ROYD_ANDROID_VERSION="$android_version" ROYD_HAL_PROFILE="$hal_profile" ROYD_GRAPHICS_BACKEND="$graphics_backend" "$image_runner" "$arch" "$image_profile" "$image"
run_stage qualification env \
  ROYD_ANDROID_VERSION="$android_version" ROYD_QUALIFY_ARCH="$arch" ROYD_ANDROID_PROFILE="$image_profile" \
  ROYD_HAL_PROFILE="$hal_profile" ROYD_SECURITY_MODE="$security_mode" ROYD_GRAPHICS_BACKEND="$graphics_backend" \
  ROYD_PROFILE="$runtime_profile" ROYD_IMAGE="$image" "$qualification_runner"
run_stage reference env \
  ROYD_ANDROID_VERSION="$android_version" ROYD_HAL_PROFILE="$hal_profile" ROYD_SECURITY_MODE="$security_mode" \
  ROYD_GRAPHICS_BACKEND="$graphics_backend" ROYD_PROFILE="$runtime_profile" ROYD_IMAGE="$image" \
  ROYD_REPORT_OUTPUT="$output/reference-host.md" "$reference_runner" "$image"

if [ "$include_memory" -eq 1 ]; then
  run_stage memory env \
    ROYD_ANDROID_VERSION="$android_version" ROYD_QUALIFY_ARCH="$arch" ROYD_ARCH="$arch" \
    ROYD_ANDROID_PROFILE="$image_profile" ROYD_HAL_PROFILE="$hal_profile" ROYD_SECURITY_MODE="$security_mode" \
    ROYD_GRAPHICS_BACKEND="$graphics_backend" ROYD_PROFILE="$runtime_profile" ROYD_IMAGE="$image" \
    ROYD_MEMORY_SWEEP_OUTPUT="$output/memory.md" "$memory_runner" "$image"
fi
if [ "$include_capability_sweep" -eq 1 ]; then
  run_stage capability env \
    ROYD_ANDROID_VERSION="$android_version" ROYD_QUALIFY_ARCH="$arch" ROYD_ANDROID_PROFILE="$image_profile" \
    ROYD_HAL_PROFILE="$hal_profile" ROYD_SECURITY_MODE=experimental ROYD_GRAPHICS_BACKEND="$graphics_backend" \
    ROYD_PROFILE="$runtime_profile" ROYD_IMAGE="$image" ROYD_SECURITY_CAPABILITY_SWEEP_OUTPUT="$output/security-capabilities.md" \
    "$capability_runner" "$image"
fi

runtime_result=${ROYD_RUNTIME_RESULT_FILE:-}
if [ -z "$runtime_result" ]; then
  runtime_result="$work_root/runtime-results/$(runtime_result_key "$android_version" "$arch" "$image_profile" "$hal_profile" "$security_mode" "$graphics_backend")"
fi
if [ -f "$runtime_result" ]; then
  cp "$runtime_result" "$output/runtime-result.env"
else
  printf 'warning: runtime result was not produced: %s\n' "$runtime_result" >> "$log"
  qualification_status=fail
  overall=fail
fi

ended=$(date -u +%Y-%m-%dT%H:%M:%SZ)
cat > "$output/manifest.env" <<MANIFEST
ROYD_REFERENCE_BUNDLE_FORMAT=1
RESULT_STATUS=$overall
STARTED_AT=$started
FINISHED_AT=$ended
ANDROID_VERSION=$android_version
AOSP_TAG=$AOSP_TAG
ARCH=$arch
IMAGE=$image
IMAGE_PROFILE=$image_profile
PROFILE_POLICY=$profile_policy
PROFILE_POLICY_SHA256=$profile_policy_sha256
HAL_PROFILE=$hal_profile
GRAPHICS_BACKEND=$graphics_backend
RUNTIME_PROFILE=$runtime_profile
SECURITY_MODE=$security_mode
SECURITY_PROFILE=$security_profile
SECURITY_PROFILE_SHA256=$security_profile_sha256
HOST_STATUS=$host_status
IMAGE_STATUS=$image_status
QUALIFICATION_STATUS=$qualification_status
REFERENCE_STATUS=$reference_status
MEMORY_STATUS=$memory_status
CAPABILITY_SWEEP_STATUS=$capability_status
MANIFEST

(
  cd "$output"
  find . -type f ! -name SHA256SUMS -print | LC_ALL=C sort | sed 's#^./##' | while IFS= read -r file; do
    sha256sum "$file"
  done > SHA256SUMS
)

printf 'Reference-host evidence bundle written to %s\n' "$output"
printf 'Result: %s\n' "$overall"
[ "$overall" = pass ]
