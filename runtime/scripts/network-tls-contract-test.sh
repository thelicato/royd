#!/bin/sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
source_dir=$root/runtime/tests/network-tls
go test "$source_dir/probe.go" "$source_dir/probe_test.go"
grep -Fq 'android:usesCleartextTraffic="false"' "$source_dir/AndroidManifest.xml"
[ "$(grep -c '<uses-permission ' "$source_dir/AndroidManifest.xml")" -eq 2 ]
! grep -Eq 'sharedUserId|networkSecurityConfig|debuggable' "$source_dir/AndroidManifest.xml"
! grep -Eq 'set.*(HostnameVerifier|SSLSocketFactory)|TrustManager|SSLContext|setProperty|bindProcessToNetwork|openConnection\(.*Proxy' "$source_dir/TlsProbe.java"
grep -Fq 'connection.setInstanceFollowRedirects(false);' "$source_dir/TlsProbe.java"
grep -Fq 'testkey.pk8' "$script_dir/network-tls-build.sh"
! grep -Fq 'platform.pk8' "$script_dir/network-tls-build.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir "$tmp/bin"
go build -o "$tmp/helper" "$source_dir/probe.go"
if [ -n "${ROYD_TEST_JAVA_HOME:-}" ]; then
  printf '%s\n' 'import javax.net.ssl.SSLHandshakeException;' 'import java.security.cert.*;' 'class TrustFailure {' >"$tmp/TrustFailure.java"
  awk '/^    private static boolean isCertificateTrustFailure/ { copy=1 }
    copy { print }
    copy && /^    }/ { exit }' "$source_dir/TlsProbe.java" >>"$tmp/TrustFailure.java"
  cat >>"$tmp/TrustFailure.java" <<'JAVA'
    public static void main(String[] args) throws Exception {
        for (Throwable cause : new Throwable[] {new CertificateException(), new CertPathValidatorException(),
                new java.io.IOException(), new java.net.SocketTimeoutException()}) {
            SSLHandshakeException error = new SSLHandshakeException("test"); error.initCause(cause);
            boolean expected = cause instanceof CertificateException || cause instanceof CertPathValidatorException;
            if (isCertificateTrustFailure(error) != expected || isCertificateTrustFailure(cause)) {
                throw new AssertionError();
            }
        }
        if (isCertificateTrustFailure(new SSLHandshakeException("certificate failure text is not proof"))) {
            throw new AssertionError();
        }
        System.out.println("Production TLS certificate-failure classifier passed");
    }
}
JAVA
  "$ROYD_TEST_JAVA_HOME/bin/javac" -d "$tmp" "$tmp/TrustFailure.java"
  "$ROYD_TEST_JAVA_HOME/bin/java" -cp "$tmp" TrustFailure
else
  printf '%s\n' 'Java execution skipped: set ROYD_TEST_JAVA_HOME for TLS failure-classifier contracts'
fi
cat >"$tmp/bin/build" <<'MOCK'
#!/bin/sh
set -eu
mkdir "$1"
: >"$1/probe.apk"
cp "$MOCK_TOOLS/fixture" "$1/tls-fixture"
MOCK
cat >"$tmp/bin/fixture" <<'MOCK'
#!/bin/sh
set -eu
if [ "$1" != -listen ]; then exec "$MOCK_HELPER" "$@"; fi
[ "$MOCK_CASE" != fixture_failure ] || exit 1
printf '%s\n' UNTRUSTED_URL=https://172.17.0.1:43210/reject
if [ "$MOCK_CASE" = unexpected_request ]; then printf '%s\n' UNTRUSTED_HTTP_REQUEST=unexpected; fi
while :; do sleep 0.05; done
MOCK
cat >"$tmp/bin/docker" <<'MOCK'
#!/bin/sh
set -eu
printf '%s\n' "$*" >>"$MOCK_STATE/docker.log"
case "$1" in
  context) if [ "$MOCK_CASE" = remote ]; then printf '%s\n' ssh://remote; else printf '%s\n' unix:///var/run/docker.sock; fi ;;
  image) printf 'sha256:%064d\n' 1 ;;
  network)
    case "$2" in
      create) : >"$MOCK_STATE/network" ;;
      rm) rm "$MOCK_STATE/network" ;;
      inspect) [ "$3" = bridge ] || [ -e "$MOCK_STATE/network" ] || [ "$MOCK_CASE" = existing_network ]; printf '%s\n' 172.17.0.1 ;;
      *) exit 99 ;;
    esac ;;
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
      *'getprop ro.build.version.sdk') if [ "$MOCK_CASE" = wrong_sdk ]; then printf '%s\n' 34; else printf '%s\n' 35; fi ;;
      *'pidof system_server')
        if [ "$MOCK_CASE" = server_changed ] && [ "$(cat "$MOCK_STATE/asserts")" = 2 ]; then printf '%s\n' 501; else printf '%s\n' 500; fi ;;
      *'pidof org.royd.tlsprobe') printf '%s\n' 900 ;;
      *'stat -c %u /proc/900') if [ "$MOCK_CASE" = root_app ]; then printf '%s\n' 0; else printf '%s\n' 10054; fi ;;
      *'stat -c %u /data/user/'*) if [ "$MOCK_CASE" = wrong_owner ]; then printf '%s\n' 10055; else printf '%s\n' 10054; fi ;;
      *'pm install -t '*) [ "$MOCK_CASE" != install_failure ]; printf '%s\n' Success ;;
      *'am start -W '*) printf '%s\n' 'Status: ok' 'Activity: org.royd.tlsprobe/.TlsProbe' ;;
      *'test -s '*) [ "$MOCK_CASE" != no_result ] ;;
      *'cat /data/user/'*)
        raw='{"uid":10054,"done":true,"url":"https://www.google.com/generate_204","untrusted_url":"https://172.17.0.1:43210/reject","active_network":"100","active_interface":"eth0","configured_dns":["127.0.0.11"],"default_callback_available":1,"dns_answers":["142.250.1.1"],"public_https":"pass","http_status":204,"cipher_suite":"TLS_AES_256_GCM_SHA384","peer_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","peer_subject":"CN=www.google.com","peer_issuer":"CN=issuer","body_bytes":0,"body_sha256":"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855","untrusted_rejected":true,"untrusted_causes":["javax.net.ssl.SSLHandshakeException","java.security.cert.CertPathValidatorException"]}'
        case "$MOCK_CASE" in
          public_failure|both_failures) printf '%s\n' "$raw" | sed 's/"public_https":"pass"/"public_https":"fail"/' ;;
          trust_failure) printf '%s\n' "$raw" | sed 's/"untrusted_rejected":true/"untrusted_rejected":false/' ;;
          wrong_uid) printf '%s\n' "$raw" | sed 's/10054/10055/' ;;
          *) printf '%s\n' "$raw" ;;
        esac ;;
      *'ip -o -4 addr show dev eth0;'*)
        printf '%s\n' '2: eth0 inet 172.17.0.2/16 scope global' 'default via 172.17.0.1 dev eth0'
        if [ "$MOCK_CASE" = ownership_changed ] && [ "$(cat "$MOCK_STATE/asserts")" = 2 ]; then printf '%s\n' changed; fi ;;
      *'dumpsys '*|*'logcat -d '*|*'screencap -p'|*'cat /etc/resolv.conf; ip rule;'*) printf '%s\n' evidence ;;
      *) printf 'unexpected exec: %s\n' "$*" >&2; exit 99 ;;
    esac ;;
  *) exit 99 ;;
esac
MOCK
cat >"$tmp/bin/assert" <<'MOCK'
#!/bin/sh
set -eu
count=$(cat "$MOCK_STATE/asserts"); count=$((count + 1)); printf '%s\n' "$count" >"$MOCK_STATE/asserts"
[ "$MOCK_CASE:$count" != before_failure:1 ]
[ "$MOCK_CASE:$count" != after_failure:2 ]
[ "$MOCK_CASE:$count" != both_failures:2 ]
MOCK
printf '%s\n' '#!/bin/sh' 'exit 0' >"$tmp/bin/pass"
cat >"$tmp/bin/wait" <<'MOCK'
#!/bin/sh
set -eu
[ "$ROYD_BOOT_WAIT_MARKER" = 'ROYD: using delegated cgroup v2 subtree' ]
MOCK
chmod +x "$tmp/bin/"*
for mode in good private public_failure trust_failure both_failures wrong_uid ownership_changed unexpected_request \
    root_app wrong_owner fixture_failure wrong_sdk install_failure no_result before_failure after_failure \
    server_changed start_failure capture_failure remote existing_container existing_volume existing_network existing_evidence bad_url; do
  state=$tmp/$mode
  mkdir "$state"
  printf '%s\n' 0 >"$state/asserts"
  if [ "$mode" = existing_evidence ]; then mkdir "$state/evidence"; : >"$state/evidence/preserve"; fi
  network_mode=bridge
  case "$mode" in private|existing_network) network_mode=private ;; esac
  target=https://www.google.com/generate_204
  if [ "$mode" = bad_url ]; then target=http://invalid.test/; fi
  status=0
  PATH="$tmp/bin:$PATH" MOCK_CASE="$mode" MOCK_STATE="$state" MOCK_TOOLS="$tmp/bin" MOCK_HELPER="$tmp/helper" \
    ROYD_NETWORK_TLS_OUTPUT_DIR="$state/evidence" ROYD_NETWORK_TLS_NETWORK_MODE="$network_mode" \
    ROYD_NETWORK_TLS_URL="$target" ROYD_NETWORK_TLS_REQUEST_TIMEOUT=2 \
    ROYD_NETWORK_TLS_BUILD_RUNNER="$tmp/bin/build" ROYD_NETWORK_TLS_ASSERT_RUNNER="$tmp/bin/assert" \
    ROYD_NETWORK_TLS_WAIT_RUNNER="$tmp/bin/wait" ROYD_NETWORK_TLS_HEALTH_RUNNER="$tmp/bin/pass" \
    ROYD_NETWORK_TLS_SECURITY_RUNNER="$tmp/bin/pass" \
    "$script_dir/network-tls-test.sh" royd:test >"$state/result.log" 2>&1 || status=$?
  case "$mode" in
    good|private)
      [ "$status" -eq 0 ]
      for field in RESULT RUNTIME OCI_OWNERSHIP OBSERVATION PUBLIC_DNS PUBLIC_HTTPS UNTRUSTED_CERT FRAMEWORK_NETWORK CONTROL_SERVER; do
        grep -Fxq "${field}_STATUS=pass" "$state/evidence/manifest.env"
      done
      grep -Fxq TRUST_POLICY=platform-default "$state/evidence/manifest.env"
      grep -Fxq 'full container log' "$state/evidence/container/container.log"
      [ "$(cat "$state/asserts")" = 2 ] ;;
    *)
      [ "$status" -ne 0 ] || { printf 'error: TLS runner accepted %s\n' "$mode" >&2; exit 1; }
      case "$mode" in
        existing_container|existing_volume|existing_evidence|remote)
          ! grep -Eq '^(create|volume create|rm|volume rm) ' "$state/docker.log"
          [ ! -e "$state/evidence/manifest.env" ] ;;
        *) grep -Fxq RESULT_STATUS=fail "$state/evidence/manifest.env" ;;
      esac ;;
  esac
  if [ "$mode" = both_failures ]; then grep -Fxq RUNTIME_STATUS=fail "$state/evidence/manifest.env"; fi
  if [ "$mode" = unexpected_request ]; then grep -Fxq CONTROL_SERVER_STATUS=fail "$state/evidence/manifest.env"; fi
  case "$mode" in
    public_failure|both_failures)
      grep -Fxq PUBLIC_HTTPS_STATUS=fail "$state/evidence/manifest.env"
      [ "$(cat "$state/asserts")" = 2 ] ;;
    trust_failure) grep -Fxq UNTRUSTED_CERT_STATUS=fail "$state/evidence/manifest.env" ;;
    after_failure|server_changed|both_failures) grep -Fxq RUNTIME_STATUS=fail "$state/evidence/manifest.env" ;;
    ownership_changed) grep -Fxq OCI_OWNERSHIP_STATUS=fail "$state/evidence/manifest.env" ;;
  esac
  [ ! -e "$state/container" ]; [ ! -e "$state/volume" ]; [ ! -e "$state/network" ]
  ! grep -E '^create .*--(dns|add-host|network host)' "$state/docker.log"
done
printf '%s\n' 'Android 15 public DNS and HTTPS contract test passed'
