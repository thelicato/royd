#!/bin/sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
for manifest in AndroidManifest.xml PolicyControlManifest.xml; do
  [ "$(grep -c '<uses-permission ' "$root/runtime/tests/network-dns/$manifest")" -eq 2 ]
  ! grep -Eq 'sharedUserId|FOREGROUND_SERVICE|MANAGE_NETWORK|NETWORK_STACK' "$root/runtime/tests/network-dns/$manifest"
done
! grep -q startForeground "$root/runtime/tests/network-dns/MeteredProbeService.java"
go test "$root/runtime/tests/network-dns/fixture.go" "$root/runtime/tests/network-dns/policy.go" "$root/runtime/tests/network-dns/fixture_test.go" "$root/runtime/tests/network-dns/policy_test.go"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir "$tmp/bin"
go build -o "$tmp/assess" "$root/runtime/tests/network-dns/fixture.go" "$root/runtime/tests/network-dns/policy.go"
cat >"$tmp/bin/build" <<'MOCK'
#!/bin/sh
set -eu
mkdir "$1"
: >"$1/probe.apk"
: >"$1/control.apk"
cp "$MOCK_TOOLS/dns" "$1/dns-fixture"
cp "$MOCK_TOOLS/http" "$1/http-fixture"
MOCK
cat >"$tmp/bin/dns" <<'MOCK'
#!/bin/sh
set -eu
if [ "$1" = -result ] || [ "$1" = -recovery ] || [ "$1" = -policy ] || [ "$1" = -metered ] || [ "$1" = -saver ]; then exec "$MOCK_ASSESS" "$@"; fi
[ "$MOCK_CASE" != fixture_failure ] || exit 1
printf '%s\n' DNS_READY=1
while :; do sleep 0.05; done
MOCK
cat >"$tmp/bin/http" <<'MOCK'
#!/bin/sh
if [ -f "$MOCK_STATE/http-started" ]; then
  printf '%s\n' 'URL=http://172.17.0.1:43211/page/recovery-nonce'
else
  : >"$MOCK_STATE/http-started"
  printf '%s\n' 'URL=http://172.17.0.1:43210/page/nonce'
fi
while :; do sleep 0.05; done
MOCK
cat >"$tmp/bin/sleep" <<'MOCK'
#!/bin/sh
exec /bin/sleep 0.01
MOCK
cat >"$tmp/bin/docker" <<'MOCK'
#!/bin/sh
set -eu
printf '%s\n' "$*" >>"$MOCK_STATE/docker.log"
case "$1" in
  context)
    if [ "$MOCK_CASE" = remote_context ]; then printf '%s\n' ssh://remote; else printf '%s\n' unix:///var/run/docker.sock; fi ;;
  image) printf 'sha256:%064d\n' 1 ;;
  network)
    case "$2" in
      create) : >"$MOCK_STATE/network" ;;
      rm) rm "$MOCK_STATE/network" ;;
      inspect) [ "$3" = bridge ] || [ -e "$MOCK_STATE/network" ]; printf '%s\n' 172.17.0.1 ;;
      *) exit 99 ;;
    esac ;;
  inspect)
    if [ "${2:-}" = --format ]; then
      case "$3" in
        *org.royd.test.owner*)
          case "$MOCK_CASE" in recovery_unowned|policy_unowned|metered_unowned) exit 1 ;; esac
          printf 'network-dns %s\n' "$4" ;;
        *RestartCount*)
          if { [ "$MOCK_CASE" = recovery_restarted ] && [ -e "$MOCK_STATE/down" ]; } \
              || { [ "$MOCK_CASE" = datasaver_restarted ] && [ -e "$MOCK_STATE/datasaver-requested" ]; }; then
            printf '%064d start true 1 false\n' 1
          else printf '%064d start true 0 false\n' 1; fi ;;
        *) printf '%s\n' '172.17.0.2/16 172.17.0.1' ;;
      esac
      exit 0
    fi
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
      *'cmd netpolicy list restrict-background-whitelist')
        if [ "$MOCK_CASE" = saver_allowlist_failure ] && [ -e "$MOCK_STATE/datasaver-restored" ]; then exit 1; fi
        printf '%s' 'Restrict background whitelisted UIDs: '
        found=0
        for uid in 10054 10055; do if [ -e "$MOCK_STATE/allow-$uid" ]; then printf '%s ' "$uid"; found=1; fi; done
        [ "$found" = 1 ] || printf '%s' none
        printf '\n' ;;
      *'cmd netpolicy add restrict-background-whitelist '*)
        for uid in "$@"; do :; done
        : >"$MOCK_STATE/allow-$uid" ;;
      *'cmd netpolicy remove restrict-background-whitelist '*)
        for uid in "$@"; do :; done
        [ -e "$MOCK_STATE/allow-$uid" ] || { printf 'Error: UID %s not whitelisted\n' "$uid"; exit 1; }
        rm -f "$MOCK_STATE/allow-$uid" ;;
      *'cmd netpolicy list restrict-background-blacklist')
        [ "$MOCK_CASE" != metered_restore_get_failure ] || [ ! -e "$MOCK_STATE/metered-restored" ] || exit 1
        if [ -e "$MOCK_STATE/metered-deny" ] || [ "$MOCK_CASE" = metered_preexisting ]; then printf '%s\n' 'Restrict background blacklisted UIDs: 10054'
        else printf '%s\n' 'Restrict background blacklisted UIDs: none'; fi ;;
      *'cmd netpolicy add restrict-background-blacklist 10054')
        : >"$MOCK_STATE/metered-changed"
        : >"$MOCK_STATE/metered-deny"
        if [ "$MOCK_CASE" = metered_interrupt ]; then kill -TERM "$PPID"; fi
        [ "$MOCK_CASE" != metered_set_failure ] ;;
      *'cmd netpolicy remove restrict-background-blacklist 10054')
        : >"$MOCK_STATE/metered-restored"
        rm -f "$MOCK_STATE/metered-deny"
        [ "$MOCK_CASE" != metered_restore_failure ] ;;
      *'am start --user 0 '*'/org.royd.networkprobe.MeteredProbeLauncher '*)
        [ "$MOCK_CASE" != metered_service_failure ] || { printf '%s\n' 'Error: service refused'; exit 1; }
        : >"$MOCK_STATE/running"
        printf '%s\n' "$*" | sed -n 's/.*metered=\([^ ]*\).*/\1/p' >"$MOCK_STATE/metered-phase"
        printf '%s\n' 'Starting service: Intent { cmp=test }' ;;
      *'am get-uid-state '*)
        if [ "${ROYD_NETWORK_DNS_SAVER_POLICY:-0}" = 1 ] && [ "$(cat "$MOCK_STATE/metered-phase")" = foreground-target ]; then printf '%s\n' '2 (TOP)'
        else printf '%s\n' '10 (SERVICE)'; fi ;;
      *'touch /data/user/'*) : ;;
      *'cmd netpolicy set restrict-background true')
        : >"$MOCK_STATE/datasaver-requested"
        [ "$MOCK_CASE" != datasaver_command_failure ]
        case "$MOCK_CASE" in datasaver_rollback|datasaver_embedded_rollback|saver_rollback) ;; *) : >"$MOCK_STATE/datasaver" ;; esac
        case "$MOCK_CASE" in datasaver_interrupt|saver_interrupt) kill -TERM "$PPID" ;; esac ;;
      *'cmd netpolicy set restrict-background false')
        : >"$MOCK_STATE/datasaver-restored"
        case "$MOCK_CASE" in datasaver_restore_failure|saver_restore_failure) exit 1 ;; esac
        rm -f "$MOCK_STATE/datasaver" ;;
      *'cmd netpolicy get restrict-background')
        if [ -e "$MOCK_STATE/datasaver" ] || [ "$MOCK_CASE" = datasaver_preexisting ]; then
          printf '%s\n' 'Restrict background status: enabled'
        else printf '%s\n' 'Restrict background status: disabled'; fi ;;
      *'cmd connectivity set-package-networking-enabled false '*)
        : >"$MOCK_STATE/policy-changed"
        [ "$MOCK_CASE" != policy_set_failure ]
        : >"$MOCK_STATE/deny" ;;
      *'cmd connectivity set-package-networking-enabled true '*)
        : >"$MOCK_STATE/policy-restored"
        rm -f "$MOCK_STATE/deny"
        [ "$MOCK_CASE" != policy_restore_failure ] ;;
      *'cmd connectivity set-chain3-enabled true')
        : >"$MOCK_STATE/chain"
        if [ "$MOCK_CASE" = policy_interrupt ]; then kill -TERM "$PPID"; fi ;;
      *'cmd connectivity set-chain3-enabled false') rm -f "$MOCK_STATE/chain" ;;
      *'cmd connectivity get-chain3-enabled')
        if [ -e "$MOCK_STATE/chain" ] || [ "$MOCK_CASE" = policy_preexisting ]; then printf '%s\n' chain:enabled; else printf '%s\n' chain:disabled; fi ;;
      *'cmd connectivity get-package-networking-enabled '*)
        package=${4:-}
        for word in "$@"; do package=$word; done
        rule=allow
        if [ "$package" = org.royd.networkprobe ] && [ -e "$MOCK_STATE/deny" ]; then rule=deny; fi
        printf '%s:%s\n' "$package" "$rule" ;;
      *'dumpsys connectivity trafficcontroller')
        printf '%s\n' 'TrafficController' 'sUidOwnerMap:'
        if [ "${ROYD_NETWORK_DNS_SAVER_POLICY:-0}" = 1 ]; then
          for uid in 10054 10055; do
            row=BACKGROUND_MATCH
            if [ -e "$MOCK_STATE/allow-$uid" ] || { [ "$uid" = 10054 ] && [ "$(cat "$MOCK_STATE/metered-phase")" = foreground-target ]; }; then row="$row HAPPY_BOX_MATCH"; fi
            printf '%s %s\n' "$uid" "$row"
          done
          printf '%s\n' 'sUidPermissionMap:' 'current ownerMatch configuration: 4096 BACKGROUND_MATCH'
          if [ -e "$MOCK_STATE/datasaver" ]; then printf '%s\n' 'sDataSaverEnabledMap: true'; else printf '%s\n' 'sDataSaverEnabledMap: false'; fi
          exit 0
        fi
        if [ "${ROYD_NETWORK_DNS_METERED:-0}" = 1 ]; then
          row=BACKGROUND_MATCH
          if [ -e "$MOCK_STATE/metered-deny" ] && [ "$MOCK_CASE" != metered_map_failure ]; then row="$row PENALTY_BOX_USER_MATCH"; fi
          printf '%s\n' "10054 $row" '10055 BACKGROUND_MATCH' 'sUidPermissionMap:' 'sDataSaverEnabledMap: false' 'current ownerMatch configuration: 4096 BACKGROUND_MATCH'
          exit 0
        fi
        if [ "${ROYD_NETWORK_DNS_DATASAVER:-0}" = 1 ]; then
          if { [ -e "$MOCK_STATE/datasaver" ] && [ "$MOCK_CASE" != datasaver_map_mismatch ]; } || [ "$MOCK_CASE" = datasaver_preexisting_map ]; then printf '%s\n' 'sDataSaverEnabledMap: true'
          else printf '%s\n' 'sDataSaverEnabledMap: false'; fi
        fi
        if [ -e "$MOCK_STATE/chain" ]; then printf '%s\n' 'current ownerMatch configuration: 2048 OEM_DENY_3_MATCH' '10054 OEM_DENY_3_MATCH'
        else printf '%s\n' 'current ownerMatch configuration: 0'; fi ;;
      *'am force-stop --user 0 '*) rm -f "$MOCK_STATE/running" ;;
      *'rm -f /data/user/'*) : ;;
      *'cat /proc/'*'/cgroup') printf '%s\n' 0::/royd/uid_test/pid_test ;;
      *'getprop ro.build.version.sdk')
        if [ "$MOCK_CASE" = wrong_sdk ]; then printf '%s\n' 34; else printf '%s\n' 35; fi ;;
      *'pidof system_server')
        if [ "$MOCK_CASE" = server_changed ] && [ "$(cat "$MOCK_STATE/asserts")" = 2 ]; then printf '%s\n' 501; else printf '%s\n' 500; fi ;;
      *'pidof org.royd.networkprobe')
        if [ "${ROYD_NETWORK_DNS_POLICY:-0}" = 1 ] || [ "${ROYD_NETWORK_DNS_DATASAVER:-0}" = 1 ] || [ "${ROYD_NETWORK_DNS_METERED:-0}" = 1 ] || [ "${ROYD_NETWORK_DNS_SAVER_POLICY:-0}" = 1 ]; then
          [ "$MOCK_CASE" != policy_pid_error ] || exit 125
          [ "$MOCK_CASE" != metered_pid_error ] || exit 125
          if [ "$MOCK_CASE" = datasaver_pid_error ] && [ -e "$MOCK_STATE/datasaver-restored" ]; then exit 125; fi
          [ -e "$MOCK_STATE/running" ] || exit 1
        fi
        if [ "$MOCK_CASE" = recovery_process_changed ] && [ -e "$MOCK_STATE/down" ]; then printf '%s\n' 901; else printf '%s\n' 900; fi ;;
      *'pidof org.royd.networkcontrol') [ -e "$MOCK_STATE/running" ]; printf '%s\n' 901 ;;
      *'stat -c %u /proc/901') printf '%s\n' 10055 ;;
      *'stat -c %u /proc/900')
        if [ "$MOCK_CASE" = datasaver_uid_changed ] && [ -e "$MOCK_STATE/datasaver-restored" ]; then printf '%s\n' 10056; exit 0; fi
        if [ "$MOCK_CASE" = root_app ]; then printf '%s\n' 0; else printf '%s\n' 10054; fi ;;
      *'stat -c %u /data/user/'*)
        case "$*" in *org.royd.networkcontrol*) printf '%s\n' 10055; exit 0 ;; esac
        if [ "$MOCK_CASE" = wrong_owner ]; then printf '%s\n' 10055; else printf '%s\n' 10054; fi ;;
      *'pm install -t '*) [ "$MOCK_CASE" != install_failure ]; printf '%s\n' Success ;;
      *'am start -W '*)
        if [ "${ROYD_NETWORK_DNS_DATASAVER:-0}" = 1 ]; then : >"$MOCK_STATE/running"; fi
        if [ "${ROYD_NETWORK_DNS_POLICY:-0}" = 1 ]; then
          : >"$MOCK_STATE/running"
          printf '%s\n' "$*" | sed -n 's/.*policy=//p' >"$MOCK_STATE/phase"
        fi
        printf '%s\n' 'Status: ok'
        if [ "$MOCK_CASE" = wrong_activity ]; then printf '%s\n' 'Activity: other/.Activity'
        elif [ "${ROYD_NETWORK_DNS_RECOVERY:-0}" = 1 ]; then printf '%s\n' 'Activity: org.royd.networkprobe/.RecoveryProbe'
        elif [ "${ROYD_NETWORK_DNS_POLICY:-0}" = 1 ] && case "$*" in *org.royd.networkcontrol/*) true ;; *) false ;; esac; then
          printf '%s\n' 'Activity: org.royd.networkcontrol/org.royd.networkprobe.NetworkProbe'
        else printf '%s\n' 'Activity: org.royd.networkprobe/.NetworkProbe'; fi ;;
      *'test -s '*)
        [ "$MOCK_CASE" != no_result ]
        [ "$MOCK_CASE" != metered_no_result ]
        case "$*" in *lost.json) [ "$MOCK_CASE" != recovery_no_loss ] ;; esac ;;
      *'cat /data/user/0/org.royd.networkprobe/files/baseline.json'|*'cat /data/user/0/org.royd.networkprobe/files/lost.json'|*'cat /data/user/0/org.royd.networkprobe/files/recovered.json')
        resolver=172.17.0.1
        [ "${ROYD_NETWORK_DNS_NETWORK_MODE:-bridge}" != private ] || resolver=127.0.0.11
        case "$*" in
          *baseline.json) printf '%s\n' '{"phase":"baseline","uid":10054,"pid":900,"elapsed_ms":1000,"done":true,"active_network":"100","active_interface":"eth0","configured_dns":["'"$resolver"'"],"url":"http://172.17.0.1:43210/page/nonce","host":"royd-probe.test","system_dns_addresses":["172.17.0.1"],"literal_http":"pass","hostname_http":"pass","events":["available:100"]}' ;;
          *lost.json) printf '%s\n' '{"phase":"lost","uid":10054,"pid":900,"elapsed_ms":2000,"done":true,"active_network":"null","url":"http://172.17.0.1:43210/page/nonce","literal_http":"failed","literal_error":"ConnectException","events":["available:100","lost:100"]}' ;;
          *recovered.json)
            named=pass
            [ "$MOCK_CASE" != recovery_dns_failure ] || named=failed
            printf '%s\n' '{"phase":"recovered","uid":10054,"pid":900,"elapsed_ms":3000,"done":true,"active_network":"101","active_interface":"eth0","configured_dns":["'"$resolver"'"],"url":"http://172.17.0.1:43211/page/recovery-nonce","host":"recovery.royd-probe.test","system_dns_addresses":["172.17.0.1"],"literal_http":"pass","hostname_http":"'"$named"'","events":["available:100","lost:100","available:101"]}' ;;
        esac ;;
      *'cat /data/user/'*)
        if [ "${ROYD_NETWORK_DNS_METERED:-0}" = 1 ] || [ "${ROYD_NETWORK_DNS_SAVER_POLICY:-0}" = 1 ]; then
          name=$(cat "$MOCK_STATE/metered-phase")
          uid=10054; pid=900
          case "$name" in *-control) uid=10055; pid=901 ;; esac
          case "$*" in *ready.json) printf '{"uid":%s,"pid":%s}\n' "$uid" "$pid"; exit 0 ;; esac
          resolver=172.17.0.1
          [ "${ROYD_NETWORK_DNS_NETWORK_MODE:-bridge}" != private ] || resolver=127.0.0.11
          direct=pass; http=pass; named=pass; active=100; importance=300
          blocked=0
          if [ "$name" = blocked-target ] || { [ "${ROYD_NETWORK_DNS_SAVER_POLICY:-0}" = 1 ] && [ "$name" = revoked-target ]; }; then blocked=1; fi
          if [ "$blocked" = 1 ]; then
            direct='java.io.IOException: sendto failed: EPERM'; http='java.net.SocketTimeoutException: connect'; named='java.net.UnknownHostException: denied'; active=null
            case "$MOCK_CASE" in metered_leak|saver_leak) direct=pass; http=pass; named=pass ;; esac
          fi
          if [ "$blocked" = 0 ] || [ "$MOCK_CASE" = metered_leak ] || [ "$MOCK_CASE" = saver_leak ]; then
            printf 'request method="GET" path="/page/nonce" query="metered=%s" remote="test"\nrequest method="GET" path="/page/nonce" query="metered=%s" remote="test"\n' "$name" "$name" >>"$ROYD_NETWORK_DNS_OUTPUT_DIR/http-server.log"
          fi
          if [ "$MOCK_CASE:$name" = metered_control_failure:blocked-control ]; then http=failed; fi
          if [ "$MOCK_CASE" = metered_foreground ]; then importance=100; fi
          if [ "${ROYD_NETWORK_DNS_SAVER_POLICY:-0}" = 1 ] && [ "$name" = foreground-target ]; then importance=100; fi
          if [ "$MOCK_CASE:$name" = saver_exemption_failure:exempt-target ]; then http=failed; fi
          printf '%s\n' '{"uid":'"$uid"',"pid":'"$pid"',"url":"http://172.17.0.1:43210/page/nonce?metered='"$name"'","done":true,"direct_udp_dns":"'"$direct"'","literal_http":"'"$http"'","hostname_http":"'"$named"'","active_interface":"eth0","configured_dns":["'"$resolver"'"],"active_network":"'"$active"'","network_count":1,"default_callback_available":1,"system_dns_addresses":["172.17.0.1"],"network_metered":true,"importance":'"$importance"',"importance_after":'"$importance"'}'
          exit 0
        fi
        if [ "${ROYD_NETWORK_DNS_DATASAVER:-0}" = 1 ] && [ -e "$MOCK_STATE/datasaver-restored" ]; then
          printf '%s\n' 'request method="GET" path="/page/nonce" query="datasaver=restored" remote="test"' 'request method="GET" path="/page/nonce" query="datasaver=restored" remote="test"' >>"$ROYD_NETWORK_DNS_OUTPUT_DIR/http-server.log"
          named=pass
          [ "$MOCK_CASE" != datasaver_app_failure ] || named=failed
          resolver=172.17.0.1
          [ "${ROYD_NETWORK_DNS_NETWORK_MODE:-bridge}" != private ] || resolver=127.0.0.11
          printf '%s\n' '{"uid":10054,"pid":900,"done":true,"direct_udp_dns":"pass","literal_http":"pass","hostname_http":"'"$named"'","active_interface":"eth0","configured_dns":["'"$resolver"'"],"active_network":"100","network_count":1,"default_callback_available":1,"system_dns_addresses":["172.17.0.1"]}'
          exit 0
        fi
        if [ "${ROYD_NETWORK_DNS_POLICY:-0}" = 1 ]; then
          name=$(cat "$MOCK_STATE/phase")
          uid=10054; pid=900
          case "$name" in *-control) uid=10055; pid=901 ;; esac
          resolver=172.17.0.1
          [ "${ROYD_NETWORK_DNS_NETWORK_MODE:-bridge}" != private ] || resolver=127.0.0.11
          direct=pass; http=pass; named=pass; active=100
          if [ "$name" = blocked-target ]; then
            direct='java.io.IOException: sendto failed: EPERM'
            http='java.net.SocketTimeoutException: connect'
            named='java.net.UnknownHostException: denied'
            active=null
            if [ "$MOCK_CASE" = policy_leak ]; then http=pass; fi
          else
            printf 'request method="GET" path="/page/nonce" query="policy=%s" remote="test"\nrequest method="GET" path="/page/nonce" query="policy=%s" remote="test"\n' "$name" "$name" >>"$ROYD_NETWORK_DNS_OUTPUT_DIR/http-server.log"
            if [ "$MOCK_CASE:$name" = policy_control_failure:blocked-control ]; then http=failed; fi
          fi
          printf '%s\n' '{"uid":'"$uid"',"pid":'"$pid"',"url":"http://172.17.0.1:43210/page/nonce?policy='"$name"'","done":true,"direct_udp_dns":"'"$direct"'","literal_http":"'"$http"'","hostname_http":"'"$named"'","active_interface":"eth0","configured_dns":["'"$resolver"'"],"active_network":"'"$active"'","network_count":1,"default_callback_available":1,"system_dns_addresses":["172.17.0.1"]}'
          exit 0
        fi
        if [ "$MOCK_CASE" = dns_gap ] || [ "$MOCK_CASE" = both_gaps ]; then
          printf '%s\n' '{"uid":10054,"done":true,"direct_udp_dns":"pass","literal_http":"pass","active_network":"null","network_count":0,"default_callback_available":0,"system_dns_addresses":[]}'
        elif [ "$MOCK_CASE" = embedded ] || [ "${ROYD_NETWORK_DNS_NETWORK_MODE:-bridge}" = private ]; then
          printf '%s\n' '{"uid":10054,"done":true,"direct_udp_dns":"pass","literal_http":"pass","hostname_http":"pass","active_interface":"eth0","configured_dns":["127.0.0.11"],"active_network":"100","network_count":1,"default_callback_available":1,"system_dns_addresses":["172.17.0.1"]}'
        else
          printf '%s\n' '{"uid":10054,"done":true,"direct_udp_dns":"pass","literal_http":"pass","hostname_http":"pass","active_interface":"eth0","configured_dns":["172.17.0.1"],"active_network":"100","network_count":1,"default_callback_available":1,"system_dns_addresses":["172.17.0.1"]}'
        fi ;;
      *'ip -o -4 addr show dev eth0;'*)
        printf '%s\n' '2: eth0 inet 172.17.0.2/16 scope global' 'default via 172.17.0.1 dev eth0'
        case "$MOCK_CASE" in ownership_changed|recovery_ownership_changed)
          if [ "$(cat "$MOCK_STATE/asserts")" = 2 ]; then printf '%s\n' changed; fi ;;
        esac ;;
      *'ip link set dev eth0 down')
        : >"$MOCK_STATE/down"
        if [ "$MOCK_CASE" = recovery_interrupt ]; then kill -TERM "$PPID"; fi
        [ "$MOCK_CASE" != recovery_down_failure ] ;;
      *'ip link set dev eth0 up'*)
        : >"$MOCK_STATE/restored"
        [ "$MOCK_CASE" != recovery_restore_failure ] ;;
      *'input keyevent KEYCODE_WAKEUP'|*'wm dismiss-keyguard') : ;;
      *'dumpsys connectivity') printf '%s\n' 'Active default network: none' ;;
      *'dumpsys netpolicy') printf '%s\n' 'Metered ifaces: {eth0}' ;;
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
[ "$MOCK_CASE:$count" != recovery_post_failure:2 ]
[ "$MOCK_CASE:$count" != policy_post_failure:2 ]
[ "$MOCK_CASE:$count" != datasaver_post_failure:2 ]
[ "$MOCK_CASE:$count" != metered_post_failure:2 ]
[ "$MOCK_CASE:$count" != saver_post_failure:2 ]
MOCK
cat >"$tmp/bin/pass" <<'MOCK'
#!/bin/sh
exit 0
MOCK
chmod +x "$tmp/bin/"*
for mode in good embedded dns_gap both_gaps ownership_changed fixture_failure wrong_sdk root_app wrong_owner install_failure no_result \
    wrong_activity before_failure after_failure server_changed start_failure capture_failure \
    remote_context existing_container existing_volume existing_evidence \
    recovery_good recovery_embedded recovery_dns_failure recovery_process_changed recovery_restarted \
    recovery_no_loss recovery_down_failure recovery_restore_failure recovery_unowned recovery_interrupt \
    recovery_post_failure recovery_ownership_changed \
    policy_good policy_embedded policy_leak policy_control_failure policy_set_failure policy_restore_failure \
    policy_interrupt policy_pid_error policy_preexisting policy_post_failure policy_unowned \
    datasaver_good datasaver_embedded datasaver_rollback datasaver_embedded_rollback datasaver_command_failure \
    datasaver_map_mismatch datasaver_restore_failure datasaver_interrupt datasaver_preexisting \
    datasaver_app_failure datasaver_post_failure datasaver_pid_error datasaver_uid_changed datasaver_restarted datasaver_preexisting_map \
    metered_good metered_embedded metered_leak metered_control_failure metered_foreground metered_preexisting metered_unowned \
    metered_set_failure metered_restore_failure metered_restore_get_failure metered_service_failure metered_pid_error metered_no_result metered_map_failure metered_interrupt metered_post_failure \
    saver_good saver_embedded saver_rollback saver_leak saver_exemption_failure saver_restore_failure saver_interrupt saver_post_failure saver_allowlist_failure; do
  state="$tmp/$mode"
  mkdir "$state"
  printf '%s\n' 0 >"$state/asserts"
  if [ "$mode" = existing_evidence ]; then mkdir "$state/evidence"; : >"$state/evidence/preserve"; fi
  status=0
  network_mode=bridge
  recovery=0
  policy=0
  datasaver=0
  metered=0
  saver=0
  case "$mode" in recovery_*) recovery=1 ;; esac
  case "$mode" in policy_*) policy=1 ;; esac
  case "$mode" in datasaver_*) datasaver=1 ;; esac
  case "$mode" in metered_*) metered=1 ;; esac
  case "$mode" in saver_*) saver=1 ;; esac
  if [ "$mode" = embedded ] || [ "$mode" = recovery_embedded ] || [ "$mode" = policy_embedded ]; then network_mode=private; fi
  case "$mode" in datasaver_embedded*) network_mode=private ;; esac
  [ "$mode" != metered_embedded ] || network_mode=private
  [ "$mode" != saver_embedded ] || network_mode=private
  PATH="$tmp/bin:$PATH" MOCK_STATE="$state" MOCK_CASE="$mode" MOCK_TOOLS="$tmp/bin" MOCK_ASSESS="$tmp/assess" \
    ROYD_NETWORK_DNS_OUTPUT_DIR="$state/evidence" ROYD_NETWORK_DNS_REQUEST_TIMEOUT=2 \
    ROYD_NETWORK_DNS_NETWORK_MODE="$network_mode" \
    ROYD_NETWORK_DNS_RECOVERY="$recovery" \
    ROYD_NETWORK_DNS_POLICY="$policy" \
    ROYD_NETWORK_DNS_DATASAVER="$datasaver" \
    ROYD_NETWORK_DNS_METERED="$metered" \
    ROYD_NETWORK_DNS_SAVER_POLICY="$saver" \
    ROYD_NETWORK_DNS_BUILD_RUNNER="$tmp/bin/build" ROYD_NETWORK_DNS_WAIT_RUNNER="$tmp/bin/pass" \
    ROYD_NETWORK_DNS_HEALTH_RUNNER="$tmp/bin/pass" ROYD_NETWORK_DNS_SECURITY_RUNNER="$tmp/bin/pass" \
    ROYD_NETWORK_DNS_ASSERT_RUNNER="$tmp/bin/assert" \
    "$script_dir/network-dns-test.sh" royd:test >"$state/result.log" 2>&1 || status=$?
  if [ "$mode" = saver_good ] || [ "$mode" = saver_embedded ]; then
    [ "$status" -eq 0 ]
    grep -Fxq RESULT_STATUS=pass "$state/evidence/manifest.env"
    grep -Fxq ROYD_NETWORK_DNS_EVIDENCE_FORMAT=7 "$state/evidence/manifest.env"
    for field in OBSERVATION PROCESS_STATE DENIAL CONTROL RESTORATION MAP SERVER; do grep -Fxq "SAVER_${field}_STATUS=pass" "$state/evidence/manifest.env"; done
    [ -e "$state/datasaver-restored" ]
    [ ! -e "$state/allow-10054" ] && [ ! -e "$state/allow-10055" ]
    [ "$(cat "$state/asserts")" = 2 ]
  elif [ "$mode" = metered_good ] || [ "$mode" = metered_embedded ]; then
    [ "$status" -eq 0 ]
    grep -Fxq RESULT_STATUS=pass "$state/evidence/manifest.env"
    grep -Fxq ROYD_NETWORK_DNS_EVIDENCE_FORMAT=6 "$state/evidence/manifest.env"
    for field in OBSERVATION BACKGROUND DENIAL CONTROL RESTORATION MAP SERVER; do grep -Fxq "METERED_${field}_STATUS=pass" "$state/evidence/manifest.env"; done
    [ -e "$state/metered-restored" ]
    [ "$(cat "$state/asserts")" = 2 ]
  elif [ "$mode" = datasaver_good ] || [ "$mode" = datasaver_embedded ]; then
    [ "$status" -eq 0 ]
    grep -Fxq RESULT_STATUS=pass "$state/evidence/manifest.env"
    grep -Fxq ROYD_NETWORK_DNS_EVIDENCE_FORMAT=5 "$state/evidence/manifest.env"
    for field in COMMAND ACTIVATION RESTORATION APP_CONTROL; do grep -Fxq "DATASAVER_${field}_STATUS=pass" "$state/evidence/manifest.env"; done
    grep -Fxq DATASAVER_ENFORCEMENT_STATUS=not-tested "$state/evidence/manifest.env"
    [ "$(cat "$state/asserts")" = 2 ]
  elif [ "$mode" = policy_good ] || [ "$mode" = policy_embedded ]; then
    [ "$status" -eq 0 ]
    grep -Fxq RESULT_STATUS=pass "$state/evidence/manifest.env"
    grep -Fxq ROYD_NETWORK_DNS_EVIDENCE_FORMAT=4 "$state/evidence/manifest.env"
    for field in OBSERVATION DENIAL CONTROL RESTORATION MAP SERVER; do
      grep -Fxq "POLICY_${field}_STATUS=pass" "$state/evidence/manifest.env"
    done
    [ -e "$state/policy-restored" ]
    [ "$(cat "$state/asserts")" = 2 ]
  elif [ "$mode" = recovery_good ] || [ "$mode" = recovery_embedded ]; then
    [ "$status" -eq 0 ]
    grep -Fxq RESULT_STATUS=pass "$state/evidence/manifest.env"
    grep -Fxq ROYD_NETWORK_DNS_EVIDENCE_FORMAT=3 "$state/evidence/manifest.env"
    for field in APP_PROCESS_STATUS BASELINE_NETWORK_STATUS NETWORK_LOSS_STATUS NETWORK_RECOVERY_STATUS RUNTIME_STATUS OCI_OWNERSHIP_STATUS; do
      grep -Fxq "$field=pass" "$state/evidence/manifest.env"
    done
    [ -f "$state/restored" ]
    [ "$(cat "$state/asserts")" = 2 ]
  elif [ "$mode" = good ] || [ "$mode" = embedded ]; then
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
    case "$mode" in
      recovery_*)
        [ "$(cat "$state/asserts")" = 2 ]
        grep -Fxq 'full container log' "$state/evidence/container/container.log"
        case "$mode" in recovery_unowned) [ ! -e "$state/down" ] ;; *) [ -e "$state/restored" ] ;; esac ;;
    esac
    case "$mode" in
      recovery_dns_failure)
        grep -Fxq WORKLOAD_STATUS=pass "$state/evidence/manifest.env"
        grep -Fxq NETWORK_RECOVERY_STATUS=fail "$state/evidence/manifest.env"
        grep -Fxq RUNTIME_STATUS=pass "$state/evidence/manifest.env" ;;
      recovery_post_failure)
        grep -Fxq WORKLOAD_STATUS=pass "$state/evidence/manifest.env"
        grep -Fxq NETWORK_RECOVERY_STATUS=pass "$state/evidence/manifest.env"
        grep -Fxq RUNTIME_STATUS=fail "$state/evidence/manifest.env" ;;
      recovery_ownership_changed)
        grep -Fxq WORKLOAD_STATUS=pass "$state/evidence/manifest.env"
        grep -Fxq OCI_OWNERSHIP_STATUS=fail "$state/evidence/manifest.env" ;;
      recovery_*) grep -Fxq WORKLOAD_STATUS=fail "$state/evidence/manifest.env" ;;
    esac
    case "$mode" in
      policy_*)
        [ "$(cat "$state/asserts")" = 2 ]
        grep -Fxq 'full container log' "$state/evidence/container/container.log"
        if [ -e "$state/policy-changed" ]; then [ -e "$state/policy-restored" ]; fi
        case "$mode" in
          policy_leak) grep -Fxq POLICY_DENIAL_STATUS=fail "$state/evidence/manifest.env" ;;
          policy_control_failure) grep -Fxq POLICY_CONTROL_STATUS=fail "$state/evidence/manifest.env" ;;
          policy_post_failure) grep -Fxq RUNTIME_STATUS=fail "$state/evidence/manifest.env" ;;
          *) grep -Fxq WORKLOAD_STATUS=fail "$state/evidence/manifest.env" ;;
        esac ;;
    esac
    case "$mode" in
      metered_*)
        [ "$(cat "$state/asserts")" = 2 ]
        grep -Fxq 'full container log' "$state/evidence/container/container.log"
        if [ -e "$state/metered-changed" ]; then [ -e "$state/metered-restored" ]; fi
        case "$mode" in
          metered_leak) grep -Fxq METERED_DENIAL_STATUS=fail "$state/evidence/manifest.env" ;;
          metered_control_failure) grep -Fxq METERED_CONTROL_STATUS=fail "$state/evidence/manifest.env" ;;
          metered_foreground) grep -Fxq METERED_BACKGROUND_STATUS=fail "$state/evidence/manifest.env" ;;
          metered_post_failure) grep -Fxq RUNTIME_STATUS=fail "$state/evidence/manifest.env" ;;
          *) grep -Fxq WORKLOAD_STATUS=fail "$state/evidence/manifest.env" ;;
        esac ;;
    esac
    case "$mode" in
      saver_*)
        [ "$(cat "$state/asserts")" = 2 ]
        grep -Fxq 'full container log' "$state/evidence/container/container.log"
        [ -e "$state/datasaver-restored" ]
        if [ "$mode" != saver_allowlist_failure ]; then [ ! -e "$state/allow-10054" ] && [ ! -e "$state/allow-10055" ]; fi
        case "$mode" in
          saver_leak) grep -Fxq SAVER_DENIAL_STATUS=fail "$state/evidence/manifest.env" ;;
          saver_exemption_failure) grep -Fxq SAVER_RESTORATION_STATUS=fail "$state/evidence/manifest.env" ;;
          saver_post_failure) grep -Fxq RUNTIME_STATUS=fail "$state/evidence/manifest.env" ;;
        esac ;;
      datasaver_*)
        [ "$(cat "$state/asserts")" = 2 ]
        grep -Fxq 'full container log' "$state/evidence/container/container.log"
        grep -Fxq DATASAVER_ENFORCEMENT_STATUS=not-tested "$state/evidence/manifest.env"
        case "$mode" in
          datasaver_preexisting|datasaver_preexisting_map) [ ! -e "$state/datasaver-requested" ] ;;
          *) [ -e "$state/datasaver-restored" ] ;;
        esac
        case "$mode" in
          datasaver_rollback|datasaver_embedded_rollback|datasaver_map_mismatch)
            grep -Fxq DATASAVER_COMMAND_STATUS=pass "$state/evidence/manifest.env"
            grep -Fxq DATASAVER_ACTIVATION_STATUS=fail "$state/evidence/manifest.env"
            grep -Fxq DATASAVER_RESTORATION_STATUS=pass "$state/evidence/manifest.env"
            grep -Fxq DATASAVER_APP_CONTROL_STATUS=pass "$state/evidence/manifest.env" ;;
          datasaver_app_failure) grep -Fxq DATASAVER_APP_CONTROL_STATUS=fail "$state/evidence/manifest.env" ;;
          datasaver_command_failure) grep -Fxq DATASAVER_COMMAND_STATUS=fail "$state/evidence/manifest.env" ;;
          datasaver_post_failure|datasaver_restarted) grep -Fxq RUNTIME_STATUS=fail "$state/evidence/manifest.env" ;;
        esac ;;
    esac
  fi
  [ ! -e "$state/container" ]
  [ ! -e "$state/volume" ]
  [ ! -e "$state/network" ]
done
for settings in 2:0 1:1 bogus:0; do
  state="$tmp/invalid-saver-$settings"
  mkdir "$state"
  status=0
  PATH="$tmp/bin:$PATH" MOCK_STATE="$state" MOCK_CASE=invalid \
    ROYD_NETWORK_DNS_OUTPUT_DIR="$state/evidence" ROYD_NETWORK_DNS_SAVER_POLICY="${settings%:*}" ROYD_NETWORK_DNS_METERED="${settings#*:}" \
    "$script_dir/network-dns-test.sh" royd:test >"$state/result.log" 2>&1 || status=$?
  [ "$status" -eq 2 ]
  [ ! -e "$state/evidence" ]
  [ ! -e "$state/docker.log" ]
done
for settings in 2:0 1:1 bogus:0; do
  state="$tmp/invalid-$settings"
  mkdir "$state"
  status=0
  PATH="$tmp/bin:$PATH" MOCK_STATE="$state" MOCK_CASE=invalid \
    ROYD_NETWORK_DNS_OUTPUT_DIR="$state/evidence" ROYD_NETWORK_DNS_POLICY="${settings%:*}" ROYD_NETWORK_DNS_RECOVERY="${settings#*:}" \
    "$script_dir/network-dns-test.sh" royd:test >"$state/result.log" 2>&1 || status=$?
  [ "$status" -eq 2 ]
  [ ! -e "$state/evidence" ]
  [ ! -e "$state/docker.log" ]
done
for settings in 2:0:0 1:1:0 1:0:1; do
  state="$tmp/invalid-datasaver-$settings"
  mkdir "$state"
  status=0
  rest=${settings#*:}
  PATH="$tmp/bin:$PATH" MOCK_STATE="$state" MOCK_CASE=invalid \
    ROYD_NETWORK_DNS_OUTPUT_DIR="$state/evidence" ROYD_NETWORK_DNS_DATASAVER="${settings%%:*}" \
    ROYD_NETWORK_DNS_POLICY="${rest%:*}" ROYD_NETWORK_DNS_RECOVERY="${rest#*:}" \
    "$script_dir/network-dns-test.sh" royd:test >"$state/result.log" 2>&1 || status=$?
  [ "$status" -eq 2 ]
  [ ! -e "$state/evidence" ]
  [ ! -e "$state/docker.log" ]
done
for settings in 2:0:0:0 1:1:0:0 1:0:1:0 1:0:0:1; do
  state="$tmp/invalid-metered-$settings"
  mkdir "$state"
  status=0
  rest=${settings#*:}
  PATH="$tmp/bin:$PATH" MOCK_STATE="$state" MOCK_CASE=invalid \
    ROYD_NETWORK_DNS_OUTPUT_DIR="$state/evidence" ROYD_NETWORK_DNS_METERED="${settings%%:*}" \
    ROYD_NETWORK_DNS_DATASAVER="${rest%%:*}" ROYD_NETWORK_DNS_POLICY="$(printf '%s' "$rest" | cut -d: -f2)" ROYD_NETWORK_DNS_RECOVERY="${rest##*:}" \
    "$script_dir/network-dns-test.sh" royd:test >"$state/result.log" 2>&1 || status=$?
  [ "$status" -eq 2 ]
  [ ! -e "$state/evidence" ]
  [ ! -e "$state/docker.log" ]
done
printf '%s\n' 'Android 15 application DNS and network-state contract test passed'
