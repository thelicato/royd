#!/bin/sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir "$tmp/bin"
cat >"$tmp/bin/docker" <<'MOCK'
#!/bin/sh
set -eu
printf '%s\n' "$*" >>"$MOCK_STATE/docker.log"
current=$(cat "$MOCK_STATE/phase" 2>/dev/null || printf fresh)
case "$1" in
  image) printf 'sha256:%064d\n' 1 ;;
  volume)
    case "$2" in
      inspect) [ "$MOCK_CASE" = existing_volume ] ;;
      create) : >"$MOCK_STATE/volume" ;;
      rm) rm "$MOCK_STATE/volume" ;;
      *) exit 99 ;;
    esac
    ;;
  inspect)
    case "$2" in
      --format)
        [ -e "$MOCK_STATE/container" ]
        if [ "$3" = '{{.Id}} {{.State.StartedAt}}' ]; then
          id=container-one
          start=start-one
          case "$current" in
            restart) [ "$MOCK_CASE" = no_restart ] || start=start-two ;;
            recreate) start=start-three; [ "$MOCK_CASE" = no_recreate ] || id=container-two ;;
          esac
          printf '%s %s\n' "$id" "$start"
        else
          printf '%s\n' 'running=true' 'health=healthy'
        fi
        ;;
      *)
        [ "$MOCK_CASE" = existing_container ] || [ -e "$MOCK_STATE/container" ]
        printf '%s\n' '[{"State":{"Running":true}}]'
        ;;
    esac
    ;;
  create)
    if [ -e "$MOCK_STATE/created-before" ]; then
      printf '%s\n' recreate >"$MOCK_STATE/phase"
      [ "$MOCK_CASE" != create_failure ] || exit 1
    else
      : >"$MOCK_STATE/created-before"
      printf '%s\n' fresh >"$MOCK_STATE/phase"
    fi
    : >"$MOCK_STATE/container"
    printf '%s\n' created
    ;;
  start) [ "$MOCK_CASE" != start_failure ] ;;
  restart)
    printf '%s\n' restart >"$MOCK_STATE/phase"
    [ "$MOCK_CASE" != restart_failure ]
    ;;
  stop) [ "$MOCK_CASE" != stop_failure ] ;;
  rm) rm "$MOCK_STATE/container" ;;
  logs)
    [ "$MOCK_CASE" != capture_failure ]
    printf '%s\n' 'full container log'
    ;;
  exec)
    case "$*" in
      *'getprop ro.build.version.sdk')
        if [ "$MOCK_CASE" = wrong_sdk ]; then printf '%s\n' 34; else printf '%s\n' 35; fi
        ;;
      *'royd-restart-seed-persistence'*)
        [ "$MOCK_CASE" != seed_failure ] || exit 1
        for arg do token=$arg; done
        printf '%s\n' "$token" >"$MOCK_STATE/token"
        ;;
      *'royd-restart-read-persistence'*)
        [ "$MOCK_CASE" != read_failure ] || exit 1
        hash=$(printf '%064d' 1)
        token=$(cat "$MOCK_STATE/token")
        android_id=0123456789abcdef
        uid=10054
        if [ "$current" != fresh ]; then
          case "$MOCK_CASE" in
            file_changed) hash=$(printf '%064d' 2) ;;
            setting_changed) token=changed ;;
            identity_changed) android_id=fedcba9876543210 ;;
            uid_changed) uid=10055 ;;
          esac
        fi
        [ "$MOCK_CASE" != missing_identity ] || android_id=null
        printf '%s  /data/local/tmp/royd-restart-probe\n%s\n%s\n' "$hash" "$token" "$android_id"
        [ "$MOCK_CASE" = missing_package ] || printf 'package:org.chromium.webview_shell uid:%s\n' "$uid"
        ;;
      *) exit 99 ;;
    esac
    ;;
  *) exit 99 ;;
esac
MOCK
cat >"$tmp/bin/runner" <<'MOCK'
#!/bin/sh
set -eu
current=$(cat "$MOCK_STATE/phase")
stage=${0##*/}
printf '%s %s\n' "$current" "$stage" >>"$MOCK_STATE/checks.log"
[ "$MOCK_CASE" != "${stage}_failure" ] || [ "$current" != restart ]
MOCK
chmod +x "$tmp/bin/docker" "$tmp/bin/runner"
for stage in wait health security assert; do ln -s runner "$tmp/bin/$stage"; done

run_case() {
  PATH="$tmp/bin:$PATH" MOCK_STATE="$state" MOCK_CASE="$mode" \
    ROYD_RESTART_OUTPUT_DIR="$state/evidence" \
    ROYD_RESTART_WAIT_RUNNER="$tmp/bin/wait" ROYD_RESTART_HEALTH_RUNNER="$tmp/bin/health" \
    ROYD_RESTART_SECURITY_RUNNER="$tmp/bin/security" ROYD_RESTART_ASSERT_RUNNER="$tmp/bin/assert" \
    "$script_dir/restart-test.sh" royd:test >"$state/result.log" 2>&1
}

for mode in good file_changed setting_changed identity_changed uid_changed missing_identity \
    missing_package no_restart no_recreate wrong_sdk seed_failure read_failure \
    wait_failure health_failure security_failure assert_failure start_failure restart_failure \
    stop_failure create_failure capture_failure existing_container existing_volume existing_evidence; do
  state="$tmp/$mode"
  mkdir "$state"
  if [ "$mode" = existing_evidence ]; then
    mkdir "$state/evidence"
    printf '%s\n' preserve >"$state/evidence/user-file"
  fi
  status=0
  run_case || status=$?
  if [ "$mode" = good ]; then
    [ "$status" -eq 0 ]
    grep -Fxq RESULT_STATUS=pass "$state/evidence/manifest.env"
    [ "$(grep -c ' assert$' "$state/checks.log")" -eq 3 ]
    [ "$(grep -c '^create .*sha256:0*1 ' "$state/docker.log")" -eq 2 ]
    grep -q '^restart -t 10 ' "$state/docker.log"
    grep -q '^stop -t 10 ' "$state/docker.log"
    for phase in fresh restart recreate; do
      grep -Fxq 'full container log' "$state/evidence/$phase/container.log"
      [ -s "$state/evidence/$phase/container-inspect.json" ]
      [ -s "$state/evidence/$phase/persistence.txt" ]
      [ -f "$state/evidence/$phase/runtime.log" ]
    done
  else
    if [ "$status" -eq 0 ]; then
      printf 'error: restart test accepted %s\n' "$mode" >&2
      exit 1
    fi
    case "$mode" in
      existing_*)
        ! grep -Eq '^(create|volume create|rm|volume rm|restart|stop) ' "$state/docker.log"
        if [ "$mode" = existing_evidence ]; then
          [ "$(cat "$state/evidence/user-file")" = preserve ]
          [ ! -e "$state/evidence/manifest.env" ]
        fi
        ;;
      *)
        grep -Fxq RESULT_STATUS=fail "$state/evidence/manifest.env"
        ! grep -Fxq RECREATE_STATUS=pass "$state/evidence/manifest.env"
        [ -s "$state/evidence/fresh/container-inspect.json" ]
        ;;
    esac
  fi
  [ ! -e "$state/container" ]
  [ ! -e "$state/volume" ]
done
printf '%s\n' 'Android 15 persistent-data restart contract test passed'
