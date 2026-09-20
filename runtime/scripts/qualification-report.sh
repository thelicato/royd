#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
# shellcheck disable=SC1091
. "$script_dir/runtime-result-lib.sh"

work_root=${ROYD_WORK_DIR:-$repo_root/.work}
results_dir=${ROYD_RUNTIME_RESULTS_DIR:-$work_root/runtime-results}
output=${ROYD_RUNTIME_REPORT_OUTPUT:-}
image_profile=${ROYD_ANDROID_PROFILE:-standard}
image_profile=$("$repo_root/android/scripts/profile.sh" "$image_profile")
hal_profile=${ROYD_HAL_PROFILE:-graphical}
hal_profile=$("$repo_root/android/scripts/hal-profile.sh" "$hal_profile")
security_mode=${ROYD_SECURITY_MODE:-privileged}
security_profile=$($script_dir/security-profile.sh "$security_mode" id)
security_profile_sha256=$($script_dir/security-profile.sh "$security_mode" digest)
graphics_backend=${ROYD_GRAPHICS_BACKEND:-software}

render() {
  printf '%s\n\n' '# royd runtime qualification results'
  printf '%s\n\n' 'A passing row records successful host, image, boot, Docker health, runtime, security, graphics, container-log, ADB, and Binder-isolation validation for that exact tuple.'
  printf 'Image profile: `%s`\n\n' "$image_profile"
  printf 'HAL profile: `%s`\n\n' "$hal_profile"
  printf 'Security mode: `%s`\n\n' "$security_mode"
  printf 'Security profile: `%s`\n\n' "$security_profile"
  printf 'Security profile SHA-256: `%s`\n\n' "$security_profile_sha256"
  printf 'Graphics backend: `%s`\n\n' "$graphics_backend"
  printf '%s\n' '| Android | Arch | Host | Image | Boot | Health | Runtime | Security | Security evidence | Graphics | Logs | ADB | Binder isolation | Result |'
  printf '%s\n' '| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |'
  for version in $("$repo_root/android/scripts/version-list.sh"); do
    for arch in x86_64 arm64; do
      file="$results_dir/$(runtime_result_key "$version" "$arch" "$image_profile" "$hal_profile" "$security_mode" "$graphics_backend")"
      if [ -f "$file" ]; then
        host=$(runtime_result_get "$file" HOST_STATUS || printf unknown)
        image=$(runtime_result_get "$file" IMAGE_STATUS || printf unknown)
        boot=$(runtime_result_get "$file" BOOT_STATUS || printf unknown)
        health=$(runtime_result_get "$file" HEALTH_STATUS || printf unknown)
        runtime=$(runtime_result_get "$file" RUNTIME_STATUS || printf unknown)
        security=$(runtime_result_get "$file" SECURITY_STATUS || printf unknown)
        security_evidence=$(runtime_result_get "$file" SECURITY_EVIDENCE_STATUS || printf unknown)
        graphics=$(runtime_result_get "$file" GRAPHICS_STATUS || printf unknown)
        logs=$(runtime_result_get "$file" LOGS_STATUS || printf unknown)
        adb=$(runtime_result_get "$file" ADB_STATUS || printf unknown)
        binder=$(runtime_result_get "$file" BINDER_ISOLATION_STATUS || printf unknown)
        result=$(runtime_result_get "$file" RESULT_STATUS || printf unknown)
      else
        host=not-run; image=not-run; boot=not-run; health=not-run; runtime=not-run
        security=not-run; security_evidence=not-run; graphics=not-run; logs=not-run; adb=not-run; binder=not-run; result=not-run
      fi
      printf '| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n' \
        "$version" "$arch" "$host" "$image" "$boot" "$health" "$runtime" "$security" "$security_evidence" "$graphics" "$logs" "$adb" "$binder" "$result"
    done
  done
}

if [ -n "$output" ]; then
  mkdir -p "$(dirname -- "$output")"
  render > "$output"
  printf 'Runtime qualification report written to %s\n' "$output"
else
  render
fi
