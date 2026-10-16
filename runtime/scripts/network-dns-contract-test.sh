#!/bin/sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
go test "$root/runtime/tests/network-dns/fixture.go" "$root/runtime/tests/network-dns/fixture_test.go"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir "$tmp/bin"
go build -o "$tmp/assess" "$root/runtime/tests/network-dns/fixture.go"
cat >"$tmp/bin/build" <<'MOCK'
#!/bin/sh
set -eu
mkdir "$1"
: >"$1/probe.apk"
cp "$MOCK_TOOLS/dns" "$1/dns-fixture"
cp "$MOCK_TOOLS/http" "$1/http-fixture"
MOCK
cat >"$tmp/bin/dns" <<'MOCK'
#!/bin/sh
set -eu
if [ "$1" = -result ]; then exec "$MOCK_ASSESS" "$@"; fi
[ "$MOCK_CASE" != fixture_failure ] || exit 1
printf '%s\n' DNS_READY=1
while :; do sleep 0.05; done
MOCK
cat >"$tmp/bin/http" <<'MOCK'
#!/bin/sh
printf '%s\n' 'URL=http://172.17.0.1:43210/page/nonce'
while :; do sleep 0.05; done
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
    if [ "${2:-}" = --format ]; then printf '%s\n' '172.17.0.2/16 172.17.0.1'; exit 0; fi
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
  cp) exit 0 ;;
  exec)
    case "$*" in
      *'getprop ro.build.version.sdk')
        if [ "$MOCK_CASE" = wrong_sdk ]; then printf '%s\n' 34; else printf '%s\n' 35; fi ;;
      *'pidof system_server')
        if [ "$MOCK_CASE" = server_changed ] && [ "$(cat "$MOCK_STATE/asserts")" = 2 ]; then printf '%s\n' 501; else printf '%s\n' 500; fi ;;
      *'pidof org.royd.networkprobe') printf '%s\n' 900 ;;
      *'stat -c %u /proc/900')
        if [ "$MOCK_CASE" = root_app ]; then printf '%s\n' 0; else printf '%s\n' 10054; fi ;;
      *'stat -c %u /data/user/'*)
        if [ "$MOCK_CASE" = wrong_owner ]; then printf '%s\n' 10055; else printf '%s\n' 10054; fi ;;
      *'pm install -t '*) [ "$MOCK_CASE" != install_failure ]; printf '%s\n' Success ;;
      *'am start -W '*)
        printf '%s\n' 'Status: ok'
        if [ "$MOCK_CASE" = wrong_activity ]; then printf '%s\n' 'Activity: other/.Activity'; else printf '%s\n' 'Activity: org.royd.networkprobe/.NetworkProbe'; fi ;;
      *'test -s '*) [ "$MOCK_CASE" != no_result ] ;;
      *'cat /data/user/'*)
        if [ "$MOCK_CASE" = dns_gap ] || [ "$MOCK_CASE" = both_gaps ]; then
          printf '%s\n' '{"uid":10054,"done":true,"direct_udp_dns":"pass","literal_http":"pass","active_network":"null","network_count":0,"default_callback_available":0,"system_dns_addresses":[]}'
        else
          printf '%s\n' '{"uid":10054,"done":true,"direct_udp_dns":"pass","literal_http":"pass","hostname_http":"pass","active_interface":"eth0","configured_dns":["172.17.0.1"],"active_network":"100","network_count":1,"default_callback_available":1,"system_dns_addresses":["172.17.0.1"]}'
        fi ;;
      *'ip -o -4 addr show dev eth0;'*)
        printf '%s\n' '2: eth0 inet 172.17.0.2/16 scope global' 'default via 172.17.0.1 dev eth0'
        if [ "$MOCK_CASE" = ownership_changed ] && [ "$(cat "$MOCK_STATE/asserts")" = 2 ]; then printf '%s\n' changed; fi ;;
      *'dumpsys '*|*'logcat -d '*|*'screencap -p'|*'cat /etc/resolv.conf; ip rule;'*) printf '%s\n' evidence ;;
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
[ "$MOCK_CASE:$count" != both_gaps:2 ]
MOCK
cat >"$tmp/bin/pass" <<'MOCK'
#!/bin/sh
exit 0
MOCK
chmod +x "$tmp/bin/"*
for mode in good dns_gap both_gaps ownership_changed fixture_failure wrong_sdk root_app wrong_owner install_failure no_result \
    wrong_activity before_failure after_failure server_changed start_failure capture_failure \
    remote_context existing_container existing_volume existing_evidence; do
  state="$tmp/$mode"
  mkdir "$state"
  printf '%s\n' 0 >"$state/asserts"
  if [ "$mode" = existing_evidence ]; then mkdir "$state/evidence"; : >"$state/evidence/preserve"; fi
  status=0
  PATH="$tmp/bin:$PATH" MOCK_STATE="$state" MOCK_CASE="$mode" MOCK_TOOLS="$tmp/bin" MOCK_ASSESS="$tmp/assess" \
    ROYD_NETWORK_DNS_OUTPUT_DIR="$state/evidence" ROYD_NETWORK_DNS_REQUEST_TIMEOUT=2 \
    ROYD_NETWORK_DNS_BUILD_RUNNER="$tmp/bin/build" ROYD_NETWORK_DNS_WAIT_RUNNER="$tmp/bin/pass" \
    ROYD_NETWORK_DNS_HEALTH_RUNNER="$tmp/bin/pass" ROYD_NETWORK_DNS_SECURITY_RUNNER="$tmp/bin/pass" \
    ROYD_NETWORK_DNS_ASSERT_RUNNER="$tmp/bin/assert" \
    "$script_dir/network-dns-test.sh" royd:test >"$state/result.log" 2>&1 || status=$?
  if [ "$mode" = good ]; then
    [ "$status" -eq 0 ]
    grep -Fxq RESULT_STATUS=pass "$state/evidence/manifest.env"
    grep -Fxq SYSTEM_DNS_STATUS=pass "$state/evidence/manifest.env"
    grep -Fxq FRAMEWORK_NETWORK_STATUS=pass "$state/evidence/manifest.env"
    grep -Fxq RUNTIME_STATUS=pass "$state/evidence/manifest.env"
    grep -Fxq ROYD_NETWORK_DNS_EVIDENCE_FORMAT=2 "$state/evidence/manifest.env"
    grep -Fxq OCI_OWNERSHIP_STATUS=pass "$state/evidence/manifest.env"
    grep -Fxq 'full container log' "$state/evidence/container/container.log"
    grep -q '^create .*--dns 172.17.0.1 .*sha256:0*1 ' "$state/docker.log"
    [ "$(cat "$state/asserts")" = 2 ]
  else
    if [ "$status" -eq 0 ]; then printf 'error: DNS validation accepted %s\n' "$mode" >&2; exit 1; fi
    case "$mode" in
      existing_*|remote_context)
        ! grep -Eq '^(create|volume create|rm|volume rm) ' "$state/docker.log"
        [ ! -e "$state/evidence/manifest.env" ] ;;
      *) grep -Fxq RESULT_STATUS=fail "$state/evidence/manifest.env" ;;
    esac
    case "$mode" in
      dns_gap|both_gaps)
        grep -Fxq TRANSPORT_CONTROL_STATUS=pass "$state/evidence/manifest.env"
        grep -Fxq SYSTEM_DNS_STATUS=fail "$state/evidence/manifest.env"
        grep -Fxq FRAMEWORK_NETWORK_STATUS=fail "$state/evidence/manifest.env"
        [ "$(cat "$state/asserts")" = 2 ] ;;
      after_failure|server_changed)
        grep -Fxq SYSTEM_DNS_STATUS=pass "$state/evidence/manifest.env"
        grep -Fxq RUNTIME_STATUS=fail "$state/evidence/manifest.env" ;;
      ownership_changed) grep -Fxq OCI_OWNERSHIP_STATUS=fail "$state/evidence/manifest.env" ;;
    esac
    if [ "$mode" = both_gaps ]; then grep -Fxq RUNTIME_STATUS=fail "$state/evidence/manifest.env"; fi
  fi
  [ ! -e "$state/container" ]
  [ ! -e "$state/volume" ]
done
printf '%s\n' 'Android 15 application DNS and network-state contract test passed'
