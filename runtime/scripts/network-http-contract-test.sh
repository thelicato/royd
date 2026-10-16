#!/bin/sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
go test "$repo_root/runtime/tests/network-http/server.go" "$repo_root/runtime/tests/network-http/server_test.go"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir "$tmp/bin"
cat >"$tmp/bin/go" <<'MOCK'
#!/bin/sh
set -eu
[ "$1" = build ] && [ "$2" = -o ]
cat >"$3" <<'SERVER'
#!/bin/sh
set -eu
[ "$MOCK_CASE" != server_failure ] || exit 1
printf '%s\n' 'URL=http://172.17.0.1:43210/page/nonce'
while [ ! -e "$MOCK_STATE/launched" ]; do sleep 0.05; done
case "$MOCK_CASE" in
  no_callback) ;;
  no_page) printf '%s\n' WEBVIEW_CALLBACK=pass ;;
  *) printf '%s\n' WEBVIEW_PAGE=pass WEBVIEW_CALLBACK=pass ;;
esac
while :; do sleep 0.05; done
SERVER
chmod +x "$3"
MOCK
cat >"$tmp/bin/docker" <<'MOCK'
#!/bin/sh
set -eu
printf '%s\n' "$*" >>"$MOCK_STATE/docker.log"
case "$1" in
  context)
    if [ "$MOCK_CASE" = remote_context ]; then printf '%s\n' ssh://remote; else printf '%s\n' unix:///var/run/docker.sock; fi ;;
  image) printf 'sha256:%064d\n' 1 ;;
  network) printf '%s\n' 172.17.0.1 ;;
  inspect)
    [ "$MOCK_CASE" = existing_container ] || [ -e "$MOCK_STATE/container" ]
    printf '%s\n' '[{"State":{"Running":true}}]' ;;
  volume)
    case "$2" in
      inspect) [ "$MOCK_CASE" = existing_volume ] ;;
      create) : >"$MOCK_STATE/volume" ;;
      rm) rm "$MOCK_STATE/volume" ;;
      *) exit 99 ;;
    esac ;;
  create) : >"$MOCK_STATE/container" ;;
  start) [ "$MOCK_CASE" != start_failure ] ;;
  rm) rm "$MOCK_STATE/container" ;;
  logs) [ "$MOCK_CASE" != capture_failure ]; printf '%s\n' 'full container log' ;;
  exec)
    case "$*" in
      *'getprop ro.build.version.sdk')
        if [ "$MOCK_CASE" = wrong_sdk ]; then printf '%s\n' 34; else printf '%s\n' 35; fi ;;
      *'pidof system_server')
        if [ "$MOCK_CASE" = server_changed ] && [ "$(cat "$MOCK_STATE/asserts")" = 2 ]; then
          printf '%s\n' 501
        else printf '%s\n' 500; fi ;;
      *'pidof org.chromium.webview_shell') [ "$MOCK_CASE" != missing_app ]; printf '%s\n' 900 ;;
      *'stat -c %u /proc/900')
        if [ "$MOCK_CASE" = root_app ]; then printf '%s\n' 0; else printf '%s\n' 10054; fi ;;
      *'dumpsys connectivity') printf '%s\n' 'Active default network: none' ;;
      *'dumpsys dnsresolver') printf '%s\n' 'resolver evidence' ;;
      *'am force-stop org.chromium.webview_shell') exit 0 ;;
      *'am start -W '*)
        : >"$MOCK_STATE/launched"
        printf '%s\n' 'Status: ok'
        if [ "$MOCK_CASE" = wrong_activity ]; then printf '%s\n' 'Activity: other/.Activity'; else
          printf '%s\n' 'Activity: org.chromium.webview_shell/.WebViewBrowserActivity'
        fi ;;
      *'screencap -p') printf '%s\n' screenshot ;;
      *'ip rule; ip route '*) printf '%s\n' 'routing evidence' ;;
      *) printf 'unexpected Docker exec: %s\n' "$*" >&2; exit 99 ;;
    esac ;;
  *) exit 99 ;;
esac
MOCK
cat >"$tmp/bin/assert" <<'MOCK'
#!/bin/sh
set -eu
count=$(cat "$MOCK_STATE/asserts")
count=$((count + 1))
printf '%s\n' "$count" >"$MOCK_STATE/asserts"
[ "$MOCK_CASE:$count" != before_failure:1 ]
[ "$MOCK_CASE:$count" != after_failure:2 ]
MOCK
cat >"$tmp/bin/pass" <<'MOCK'
#!/bin/sh
exit 0
MOCK
chmod +x "$tmp/bin/go" "$tmp/bin/docker" "$tmp/bin/assert" "$tmp/bin/pass"
for mode in good no_callback no_page server_failure wrong_sdk missing_app root_app \
    wrong_activity before_failure after_failure server_changed start_failure capture_failure \
    remote_context existing_container existing_volume existing_evidence; do
  state="$tmp/$mode"
  mkdir "$state"
  printf '%s\n' 0 >"$state/asserts"
  if [ "$mode" = existing_evidence ]; then mkdir "$state/evidence"; : >"$state/evidence/preserve"; fi
  status=0
  PATH="$tmp/bin:$PATH" MOCK_STATE="$state" MOCK_CASE="$mode" \
    ROYD_NETWORK_OUTPUT_DIR="$state/evidence" ROYD_NETWORK_REQUEST_TIMEOUT=3 \
    ROYD_NETWORK_WAIT_RUNNER="$tmp/bin/pass" ROYD_NETWORK_HEALTH_RUNNER="$tmp/bin/pass" \
    ROYD_NETWORK_SECURITY_RUNNER="$tmp/bin/pass" ROYD_NETWORK_ASSERT_RUNNER="$tmp/bin/assert" \
    "$script_dir/network-http-test.sh" royd:test >"$state/result.log" 2>&1 || status=$?
  if [ "$mode" = good ]; then
    [ "$status" -eq 0 ]
    grep -Fxq RESULT_STATUS=pass "$state/evidence/manifest.env"
    grep -Fxq NETWORK_SCOPE=webview-ipv4-literal-http "$state/evidence/manifest.env"
    grep -Fxq FRAMEWORK_DEFAULT_NETWORK=none "$state/evidence/manifest.env"
    grep -Fxq DNS_STATUS=not-tested "$state/evidence/manifest.env"
    grep -Fxq TLS_STATUS=not-tested "$state/evidence/manifest.env"
    [ "$(cat "$state/asserts")" = 2 ]
    grep -q '^create .*sha256:0*1 ' "$state/docker.log"
    grep -Fxq 'full container log' "$state/evidence/container/container.log"
    [ -s "$state/evidence/application.env" ]
    [ -s "$state/evidence/webview.png" ]
  else
    if [ "$status" -eq 0 ]; then printf 'error: HTTP validation accepted %s\n' "$mode" >&2; exit 1; fi
    case "$mode" in
      existing_*|remote_context)
        ! grep -Eq '^(create|volume create|rm|volume rm) ' "$state/docker.log"
        [ ! -e "$state/evidence/manifest.env" ] ;;
      *) grep -Fxq RESULT_STATUS=fail "$state/evidence/manifest.env" ;;
    esac
    case "$mode" in
      no_callback|no_page|wrong_activity|after_failure|server_changed)
        [ -s "$state/evidence/container/container-inspect.json" ] ;;
    esac
  fi
  [ ! -e "$state/container" ]
  [ ! -e "$state/volume" ]
done
printf '%s\n' 'Android 15 literal-IP application HTTP contract test passed'
