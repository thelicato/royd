#!/bin/sh

# Sourced by qualification.sh after its per-run state has been initialised.
qualification_owner() {
  actual=$(docker inspect --format '{{index .Config.Labels "org.royd.test.owner"}} {{.Id}} {{.Image}}' "$container") || return 1
  [ "$actual" = "$owner $container_id $image_id" ]
}

qualification_volume_owner() {
  actual=$(docker volume inspect --format '{{index .Labels "org.royd.test.owner"}}' "$volume") || return 1
  [ "$actual" = "$owner" ]
}

qualification_reports() {
  for diagnostic in anr system/dropbox; do
    kind=${diagnostic##*/}
    case "$kind" in anr) status_key=ANR ;; dropbox) status_key=DROPBOX ;; esac
    if timeout 5 docker exec "$container_id" sh -c '
      if test -d "$1"; then
        printf "%s\n" ROYD_REPORT_DIRECTORY=present
      else
        printf "%s\n" ROYD_REPORT_DIRECTORY=unavailable
      fi
    ' royd-report-probe "/data/$diagnostic" >"$evidence_dir/$kind-capture.log" 2>&1; then
      reply=$(cat "$evidence_dir/$kind-capture.log")
      case "$reply" in
        ROYD_REPORT_DIRECTORY=present)
          docker cp "$container_id:/data/$diagnostic" "$evidence_dir/$kind" >>"$evidence_dir/$kind-capture.log" 2>&1 || return 1
          printf '%s_COPY_STATUS=pass\n' "$status_key" >"$evidence_dir/$kind-status.env"
          ;;
        ROYD_REPORT_DIRECTORY=unavailable)
          printf '%s_PROBE_STATUS=unavailable\n' "$status_key" >"$evidence_dir/$kind-status.env"
          ;;
        *)
          printf '%s_PROBE_STATUS=invalid-reply\n' "$status_key" >"$evidence_dir/$kind-status.env"
          return 1
          ;;
      esac
    else
      probe_status=$?
      printf '%s_PROBE_STATUS=%s\n' "$status_key" "$probe_status" >"$evidence_dir/$kind-status.env"
      return 1
    fi
  done
}

qualification_post_history() {
  [ "$android_version" = 15 ] || return 0
  "$script_dir/assert-android15-log-history.sh" "$container_id" "$graphics_backend" "$hal_profile" || return 1
  "$script_dir/assert-app-responsiveness.sh" "$container_id"
}

qualification_retain_and_remove() {
  if [ "$created" = 1 ]; then
    container_evidence_status=fail
    qualification_owner && qualification_volume_owner || return 1
    if [ "$boot_status" = pass ]; then
      run_stage post_history qualification_post_history
    fi
    # Capture after the last workload, including failures and interruptions.
    "$script_dir/container-evidence.sh" "$container_id" "$evidence_dir" >"$evidence_dir/container-capture.log" 2>&1 || return 1
    qualification_reports || return 1
    container_evidence_status=pass
    qualification_owner && qualification_volume_owner || return 1
    docker rm -f "$container_id" >"$evidence_dir/container-cleanup.log" 2>&1 || return 1
  fi
  if [ "$volume_owned" = 1 ]; then
    qualification_volume_owner || return 1
    docker volume rm "$volume" >"$evidence_dir/volume-cleanup.log" 2>&1 || return 1
  fi
  main_cleanup_status=pass
}

qualification_publish() {
  # Build the canonical result inside the new evidence directory, then publish
  # an exclusive hard link from a temporary file on the destination filesystem.
  # This keeps publication atomic across separately configured evidence/results.
  canonical_tmp="$evidence_dir/result.env.tmp"
  (
    set -C
    for item do printf '%s\n' "$item" || exit 1; done >"$canonical_tmp"
  ) || return 1
  ln -T -- "$canonical_tmp" "$evidence_dir/result.env" || return 1
  rm -f "$canonical_tmp" || return 1
  result_tmp="$result_file.tmp.$owner"
  (set -C; : >"$result_tmp") || return 1
  if cat "$evidence_dir/result.env" >"$result_tmp" && ln -T -- "$result_tmp" "$result_file"; then
    rm -f "$result_tmp"
  else
    rm -f "$result_tmp"
    return 1
  fi
}
