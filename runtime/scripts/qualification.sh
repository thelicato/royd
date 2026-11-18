#!/bin/sh
set -u

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
# shellcheck disable=SC1091
. "$repo_root/android/baseline.env"
# shellcheck disable=SC1091
. "$script_dir/runtime-result-lib.sh"

android_version=${ROYD_ANDROID_VERSION:-$ROYD_DEFAULT_ANDROID_VERSION}
version_env="$repo_root/android/versions/$android_version.env"
[ -f "$version_env" ] || {
  printf 'error: unsupported Android version: %s\n' "$android_version" >&2
  exit 2
}
# shellcheck disable=SC1090
. "$version_env"
arch=${ROYD_QUALIFY_ARCH:-x86_64}
image_profile=${ROYD_ANDROID_PROFILE:-standard}
image_profile=$("$repo_root/android/scripts/profile.sh" "$image_profile")
profile_policy=$(ROYD_ANDROID_VERSION="$android_version" "$repo_root/android/scripts/profile-policy.sh" "$image_profile")
profile_policy_sha256=$(ROYD_ANDROID_VERSION="$android_version" "$repo_root/android/scripts/profile-packages.sh" "$image_profile" | sha256sum | awk '{print $1}')
hal_profile=${ROYD_HAL_PROFILE:-graphical}
hal_profile=$("$repo_root/android/scripts/hal-profile.sh" "$hal_profile")
security_mode=${ROYD_SECURITY_MODE:-privileged}
security_profile=$($script_dir/security-profile.sh "$security_mode" id)
security_profile_sha256=$($script_dir/security-profile.sh "$security_mode" digest)
graphics_backend=${ROYD_GRAPHICS_BACKEND:-software}
graphics_backend=$(ROYD_GRAPHICS_ARCH="$arch" "$repo_root/android/scripts/graphics-backend.sh" "$graphics_backend" "$arch")
runtime_profile=${ROYD_PROFILE:-$(ROYD_HAL_PROFILE="$hal_profile" "$script_dir/default-runtime-profile.sh")}
resource_profile=${ROYD_RESOURCE_PROFILE:-low-memory}
"$script_dir/resource-profile.sh" "$resource_profile" >/dev/null
image=${ROYD_IMAGE:-$(ROYD_HAL_PROFILE="$hal_profile" "$script_dir/default-image.sh" "$image_profile" "$arch")}
require_adb=${ROYD_QUALIFY_REQUIRE_ADB:-1}
timeout=${ROYD_BOOT_TIMEOUT:-180}
health_timeout=${ROYD_HEALTH_TIMEOUT:-240}
work_root=${ROYD_WORK_DIR:-$repo_root/.work}
results_dir=${ROYD_RUNTIME_RESULTS_DIR:-$work_root/runtime-results}
result_file=${ROYD_RUNTIME_RESULT_FILE:-$results_dir/$(runtime_result_key "$android_version" "$arch" "$image_profile" "$hal_profile" "$security_mode" "$graphics_backend")}
log_file=${ROYD_RUNTIME_LOG_FILE:-${result_file%.env}.log}
evidence_dir=${ROYD_RUNTIME_EVIDENCE_DIR:-${result_file%.env}.evidence}
container=${ROYD_QUALIFY_CONTAINER:-royd-qualify-$$}
volume=${container}-data
status=0
started=$(date -u +%Y-%m-%dT%H:%M:%SZ)

case "$arch" in x86_64|arm64) ;; *) printf 'error: unsupported qualification architecture: %s\n' "$arch" >&2; exit 2 ;; esac
case "$require_adb" in 0|1) ;; *) printf '%s\n' 'error: ROYD_QUALIFY_REQUIRE_ADB must be 0 or 1' >&2; exit 2 ;; esac

# Refuse reuse before opening the result/log or touching retained companions.
if [ -e "$evidence_dir/binder-isolation" ] || [ -L "$evidence_dir/binder-isolation" ]; then
  printf '%s\n' 'error: Binder evidence already exists; choose a fresh ROYD_RUNTIME_RESULT_FILE or evidence directory' >&2
  exit 2
fi
for path in "$result_file" "$log_file" "$evidence_dir"; do
  if [ -e "$path" ] || [ -L "$path" ]; then
    printf 'error: qualification output already exists: %s; choose fresh output paths\n' "$path" >&2
    exit 2
  fi
done
for name in "$container" "$volume"; do
  if docker inspect "$name" >/dev/null 2>&1 || docker volume inspect "$name" >/dev/null 2>&1; then
    printf 'error: qualification resource already exists: %s\n' "$name" >&2
    exit 2
  fi
done
mkdir -p "$(dirname -- "$result_file")" "$(dirname -- "$log_file")" "$(dirname -- "$evidence_dir")"
mkdir "$evidence_dir" || exit 2
mkdir "$evidence_dir/stages"
(set -C; : > "$log_file") || exit 2

log() {
  printf '%s\n' "$*" | tee -a "$log_file"
}

run_stage() {
  stage_name=$1
  shift
  stage_log="$evidence_dir/stages/$stage_name.log"
  log "==> $stage_name"
  set +e
  "$@" >"$stage_log" 2>&1
  stage_status=$?
  set -e
  cat "$stage_log" >> "$log_file"
  if [ "$stage_status" -eq 0 ]; then
    eval "${stage_name}_status=pass"
    log "<== $stage_name: pass"
  else
    eval "${stage_name}_status=fail"
    log "<== $stage_name: fail"
    status=1
  fi
  return 0
}

host_status=not-run
image_status=not-run
boot_status=not-run
health_status=not-run
runtime_status=not-run
security_status=not-run
security_evidence_status=not-run
graphics_status=not-run
logs_status=not-run
adb_status=not-run
binder_isolation_status=not-run
container_evidence_status=not-run
post_history_status=not-run
main_cleanup_status=not-run
container_id=unknown
created=0
volume_owned=0
owner=$(cat /proc/sys/kernel/random/uuid)
image_id=unknown
adb_endpoint=not-run
docker_privileged=unknown
docker_cap_add=unknown
docker_cap_drop=unknown
docker_security_opt=unknown
apparmor_profile=unknown
pid1_cap_eff=unknown
pid1_cap_bnd=unknown
pid1_no_new_privs=unknown
pid1_seccomp=unknown

# shellcheck disable=SC1091
. "$script_dir/qualification-owned-lib.sh"

qualification_write_result() {
  finished=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  if [ "$status" -eq 0 ]; then
    result_status=pass
  else
    result_status=fail
  fi
  qualification_publish \
    'RESULT_FORMAT=5' \
    "ANDROID_VERSION=$android_version" \
    "AOSP_TAG=$AOSP_TAG" \
    "ARCH=$arch" \
    "IMAGE_PROFILE=$image_profile" \
    "PROFILE_POLICY=$profile_policy" \
    "PROFILE_POLICY_SHA256=$profile_policy_sha256" \
    "HAL_PROFILE=$hal_profile" \
    "SECURITY_MODE=$security_mode" \
    "SECURITY_PROFILE=$security_profile" \
    "SECURITY_PROFILE_SHA256=$security_profile_sha256" \
    "GRAPHICS_BACKEND=$graphics_backend" \
    "RUNTIME_PROFILE=$runtime_profile" \
    "RESOURCE_PROFILE=$resource_profile" \
    "IMAGE=$image" \
    "IMAGE_ID=$image_id" \
    "CONTAINER_ID=$container_id" \
    "RESOURCE_OWNER=$owner" \
    "HOST_STATUS=$host_status" \
    "IMAGE_STATUS=$image_status" \
    "BOOT_STATUS=$boot_status" \
    "HEALTH_STATUS=$health_status" \
    "RUNTIME_STATUS=$runtime_status" \
    "SECURITY_STATUS=$security_status" \
    "SECURITY_EVIDENCE_STATUS=$security_evidence_status" \
    "DOCKER_PRIVILEGED=$docker_privileged" \
    "DOCKER_CAP_ADD=$docker_cap_add" \
    "DOCKER_CAP_DROP=$docker_cap_drop" \
    "DOCKER_SECURITY_OPT=$docker_security_opt" \
    "APPARMOR_PROFILE=$apparmor_profile" \
    "PID1_CAP_EFF=$pid1_cap_eff" \
    "PID1_CAP_BND=$pid1_cap_bnd" \
    "PID1_NO_NEW_PRIVS=$pid1_no_new_privs" \
    "PID1_SECCOMP=$pid1_seccomp" \
    "GRAPHICS_STATUS=$graphics_status" \
    "LOGS_STATUS=$logs_status" \
    "ADB_STATUS=$adb_status" \
    "ADB_ENDPOINT=$adb_endpoint" \
    "BINDER_ISOLATION_STATUS=$binder_isolation_status" \
    "CONTAINER_EVIDENCE_STATUS=$container_evidence_status" \
    "POST_HISTORY_STATUS=$post_history_status" \
    "MAIN_CLEANUP_STATUS=$main_cleanup_status" \
    "RESULT_STATUS=$result_status" \
    "STARTED_AT=$started" \
    "FINISHED_AT=$finished" || return 1

  log "Runtime qualification result: $result_status"
  log "Result: $result_file"
  log "Log: $log_file"
  log "Container evidence: $evidence_dir"
  return 0
}

qualification_finish() {
  exit_status=$?
  trap - EXIT HUP INT TERM
  [ "$exit_status" -eq 0 ] || status=1
  qualification_retain_and_remove || { main_cleanup_status=fail; status=1; }
  qualification_write_result || { status=1; printf 'error: result publication failed; diagnostics retained at %s\n' "$evidence_dir" >&2; }
  exit "$status"
}

trap qualification_finish EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM

run_stage host env ROYD_SECURITY_MODE="$security_mode" ROYD_GRAPHICS_BACKEND="$graphics_backend" "$script_dir/host-check.sh"
if image_id=$(docker image inspect --format '{{.Id}}' "$image" 2>"$evidence_dir/stages/image-resolution.log"); then
  run_stage image env ROYD_ANDROID_VERSION="$android_version" ROYD_HAL_PROFILE="$hal_profile" "$script_dir/image-inspect.sh" "$arch" "$image_profile" "$image_id"
else
  image_id=unknown
  image_status=fail
  status=1
  log '<== image: fail - image identity could not be resolved'
fi

if [ "$host_status" = pass ] && [ "$image_status" = pass ]; then
  profile_args=$("$script_dir/profile.sh" "$runtime_profile")
  security_args=$("$script_dir/security-args.sh" "$security_mode")
  container_args=$("$script_dir/container-args.sh")
  gpu_args=$(ROYD_GRAPHICS_ARCH="$arch" "$script_dir/gpu-args.sh" "$graphics_backend" "$arch")
  log '==> start'
  # Creation failures never authorise adopting an existing resource.
  if docker volume create --label "org.royd.test.owner=$owner" "$volume" >"$evidence_dir/volume-create.log" 2>&1 && qualification_volume_owner; then
    volume_owned=1
  else
    log 'error: could not create an owned qualification data volume'
    status=1
    exit "$status"
  fi
  # Word splitting is intentional because helpers emit trusted Docker and Android arguments.
  # shellcheck disable=SC2086
  if container_id=$(docker create $security_args $gpu_args $container_args --name "$container" \
      --label org.royd.test=runtime-qualification --label "org.royd.test.owner=$owner" \
      -p 127.0.0.1::5555 -v "$volume:/data" "$image_id" $profile_args 2>"$evidence_dir/container-create.log"); then
    created=1
    printf '%s\n' "$container_id" >"$evidence_dir/container-id.txt"
  else
    status=1
    log '<== start: fail - owned container creation failed'
    exit "$status"
  fi
  if qualification_owner && docker start "$container_id" >"$evidence_dir/container-start.log" 2>&1; then
    run_stage security "$script_dir/assert-security.sh" "$container_id" "$security_mode"
    run_stage boot "$script_dir/wait-for-boot.sh" "$container_id" "$timeout"
    [ "$boot_status" = pass ] && run_stage health "$script_dir/wait-for-health.sh" "$container_id" "$health_timeout"
    # docker exec needs Android's mounted userspace. Record the booted init state,
    # not a transient entrypoint or unavailable executable during early mounts.
    if [ "$security_status" = pass ] && [ "$boot_status" = pass ]; then
      run_stage security_evidence "$script_dir/security-evidence.sh" "$container_id" "$security_mode"
      if [ "$security_evidence_status" = pass ]; then
        evidence_file="$evidence_dir/stages/security_evidence.log"
        evidence_get() { sed -n "s/^$1=//p" "$evidence_file" | tail -n 1; }
        docker_privileged=$(evidence_get DOCKER_PRIVILEGED)
        docker_cap_add=$(evidence_get DOCKER_CAP_ADD)
        docker_cap_drop=$(evidence_get DOCKER_CAP_DROP)
        docker_security_opt=$(evidence_get DOCKER_SECURITY_OPT)
        apparmor_profile=$(evidence_get APPARMOR_PROFILE)
        pid1_cap_eff=$(evidence_get PID1_CAP_EFF)
        pid1_cap_bnd=$(evidence_get PID1_CAP_BND)
        pid1_no_new_privs=$(evidence_get PID1_NO_NEW_PRIVS)
        pid1_seccomp=$(evidence_get PID1_SECCOMP)
      fi
    fi
    [ "$boot_status" = pass ] && run_stage runtime env ROYD_HAL_PROFILE="$hal_profile" ROYD_GRAPHICS_BACKEND="$graphics_backend" ROYD_RESOURCE_PROFILE="$resource_profile" "$script_dir/assert-runtime.sh" "$container_id"
    if [ "$boot_status" = pass ]; then
      run_stage logs sh -c 'docker logs "$1" 2>&1 | grep -Fq "[royd] logcat: forwarding Android logs to container output"' sh "$container_id"
    fi
    if [ "$boot_status" = pass ]; then
      run_stage graphics sh -c 'test "$(docker exec "$1" getprop init.svc.surfaceflinger 2>/dev/null | tr -d "\r")" = running && docker exec "$1" dumpsys SurfaceFlinger >/dev/null 2>&1' sh "$container_id"
    fi
    if [ "$boot_status" = pass ]; then
      binding=$(docker port "$container_id" 5555/tcp 2>/dev/null | head -n 1 || true)
      case "$binding" in
        *:*)
          adb_host=${binding%:*}
          adb_port=${binding##*:}
          adb_endpoint=$adb_host:$adb_port
          if command -v adb >/dev/null 2>&1; then
            run_stage adb env ROYD_ADB_HOST="$adb_host" ROYD_ADB_PORT="$adb_port" "$script_dir/adb-check.sh"
          elif [ "$require_adb" = 1 ]; then
            adb_status=fail
            status=1
            log '<== adb: fail - host adb command is required'
          else
            adb_status=skipped
            log '<== adb: skipped - host adb command is unavailable'
          fi
          ;;
        *)
          adb_status=fail
          status=1
          log '<== adb: fail - Docker did not publish port 5555'
          ;;
      esac
    fi
  else
    boot_status=fail
    health_status=not-run
    security_status=not-run
    security_evidence_status=not-run
    runtime_status=not-run
    graphics_status=not-run
    logs_status=not-run
    adb_status=not-run
    status=1
    log '<== start: fail'
  fi

else
  status=1
fi

if [ "$host_status" = pass ] && [ "$image_status" = pass ]; then
  run_stage binder_isolation env \
    ROYD_BINDER_OUTPUT_DIR="$evidence_dir/binder-isolation" \
    ROYD_ANDROID_VERSION="$android_version" \
    ROYD_HAL_PROFILE="$hal_profile" \
    ROYD_ANDROID_PROFILE="$image_profile" \
    ROYD_PROFILE="$runtime_profile" \
    ROYD_SECURITY_MODE="$security_mode" \
    ROYD_IMAGE="$image_id" \
    "$script_dir/binder-isolation-test.sh" "$image_id"
fi
exit "$status"
