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
if grep -Eq '\.proceed\(|addJavascriptInterface|MIXED_CONTENT_ALWAYS_ALLOW|set.*(HostnameVerifier|SSLSocketFactory)|TrustManager|SSLContext' "$source_dir/WebViewSession.java"; then
  printf '%s\n' 'error: WebView probe weakens trust or exposes a native JavaScript bridge' >&2
  exit 1
fi
[ "$(grep -c 'ssl.cancel();' "$source_dir/WebViewSession.java")" -eq 2 ]
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
  printf '%s\n' 'class WebViewDenial {' 'static class SslError { static final int SSL_UNTRUSTED = 3; }' >"$tmp/WebViewDenial.java"
  awk '/^    static boolean expectedRejection/ { copy=1 } copy { print } copy && /^    }/ { exit }' \
    "$source_dir/WebViewSession.java" >>"$tmp/WebViewDenial.java"
  cat >>"$tmp/WebViewDenial.java" <<'JAVA'
    public static void main(String[] args) {
        String url = "https://172.17.0.1:43210/reject";
        for (String observed : new String[] {url, "https://other.example/", null}) {
            for (int primary = -1; primary < 7; primary++) {
                for (boolean authority : new boolean[] {false, true}) {
                    boolean expected = url.equals(observed) && primary == 3 && authority;
                    if (expectedRejection(url, observed, primary, authority) != expected) throw new AssertionError();
                }
            }
        }
        System.out.println("Production WebView certificate-denial classifier passed");
    }
}
JAVA
  "$ROYD_TEST_JAVA_HOME/bin/javac" -d "$tmp" "$tmp/WebViewDenial.java"
  "$ROYD_TEST_JAVA_HOME/bin/java" -cp "$tmp" WebViewDenial
  printf '%s\n' 'class ResultName {' >"$tmp/ResultName.java"
  awk '/^    private static String resultName/ { copy=1 } copy { print } copy && /^    }/ { exit }' \
    "$source_dir/TlsProbe.java" >>"$tmp/ResultName.java"
  cat >>"$tmp/ResultName.java" <<'JAVA'
    public static void main(String[] args) {
        if (!resultName(null).equals("result.json")) throw new AssertionError();
        for (String name : new String[] {"round-001.json", "round-100.json"}) {
            if (!resultName(name).equals(name)) throw new AssertionError();
        }
        for (String name : new String[] {"", "../result.json", "/round-001.json", "round-1.json",
                "round-1000.json", "round-001.json\n", "round-001.json/extra", "round-001.json\0"}) {
            try { resultName(name); throw new AssertionError(name); }
            catch (IllegalArgumentException expected) { }
        }
        System.out.println("Production per-round result filename validation passed");
    }
}
JAVA
  "$ROYD_TEST_JAVA_HOME/bin/javac" -d "$tmp" "$tmp/ResultName.java"
  "$ROYD_TEST_JAVA_HOME/bin/java" -cp "$tmp" ResultName
  cat >"$tmp/ProbeWindow.java" <<'JAVA'
class Bundle {}
class TextView {
    TextView(Object activity) {}
    void setPadding(int a, int b, int c, int d) {}
    void setTextColor(int colour) {}
}
class WindowManager { static class LayoutParams { static final int FLAG_KEEP_SCREEN_ON = 0x80; } }
class android { static class graphics { static class Color { static final int BLACK = 0; } } }
class ProbeActivity {
    String resultFile;
    String webview;
    int flags = 0x1000;
    int flagCalls;
    void onCreate(Bundle state) {}
    ProbeActivity getIntent() { return this; }
    String getStringExtra(String name) { return name.equals("webview_url") ? webview : null; }
    ProbeActivity getWindow() { return this; }
    void addFlags(int value) { flags |= value; flagCalls++; }
    void setContentView(Object view) {}
    String resultName(String name) { return name; }
}
class ProbeWindow extends ProbeActivity {
JAVA
  # Execute the production onCreate prefix, before its asynchronous network work.
  awk '/^    @Override public void onCreate/ { copy=1 }
    copy && /^        new Thread/ { print "    }"; exit }
    copy { print }' "$source_dir/TlsProbe.java" >>"$tmp/ProbeWindow.java"
  cat >>"$tmp/ProbeWindow.java" <<'JAVA'
    public static void main(String[] args) {
        for (String target : new String[] {null, "https://www.iana.org/help/example-domains"}) {
            ProbeWindow activity = new ProbeWindow();
            activity.webview = target;
            activity.onCreate(new Bundle());
            int expected = 0x1000 | (target == null ? 0 : WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
            if (activity.flags != expected || activity.flagCalls != (target == null ? 0 : 1)) {
                throw new AssertionError("WebView must keep only its visible window awake");
            }
        }
        System.out.println("Production optional WebView visible-window policy passed");
    }
}
JAVA
  "$ROYD_TEST_JAVA_HOME/bin/javac" -d "$tmp" "$tmp/ProbeWindow.java"
  "$ROYD_TEST_JAVA_HOME/bin/java" -cp "$tmp" ProbeWindow
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
    if [ "${2:-}" = --format ]; then
      case "$3" in
        *'.State.StartedAt'*)
          started=2026-10-19T12:00:00Z
          running=true; restarts=0; oom=false
          if [ -f "$MOCK_STATE/round" ] && [ "$(cat "$MOCK_STATE/round")" -ge 2 ]; then
            case "$MOCK_CASE" in
              webview_round_restart) started=2026-10-19T12:01:00Z ;;
              webview_round_oom) oom=true ;;
              webview_round_stopped) running=false ;;
              webview_round_auto_restart) restarts=1 ;;
            esac
          fi
          printf '%064d %s %s %s %s\n' 1 "$running" "$started" "$restarts" "$oom" ;;
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
      *'getprop ro.build.version.sdk') if [ "$MOCK_CASE" = wrong_sdk ]; then printf '%s\n' 34; else printf '%s\n' 35; fi ;;
      *'pidof system_server')
        if { [ "$MOCK_CASE" = server_changed ] && [ "$(cat "$MOCK_STATE/asserts")" = 2 ]; } ||
            { [ "$MOCK_CASE" = webview_round_server ] && [ "$(cat "$MOCK_STATE/round")" -ge 2 ]; }; then
          printf '%s\n' 501
        else printf '%s\n' 500; fi ;;
      *'am force-stop --user 0 org.royd.tlsprobe') : >"$MOCK_STATE/stopped" ;;
      *'pidof org.royd.tlsprobe')
        if [ -f "$MOCK_STATE/stopped" ]; then
          case "$MOCK_CASE" in
            webview_round_stop_failure) printf '%s\n' 900 ;;
            webview_round_pid_error) exit 125 ;;
            *) exit 1 ;;
          esac
        else printf '%s\n' 900; fi ;;
      *'stat -c %u /proc/900')
        if [ "$MOCK_CASE" = root_app ]; then printf '%s\n' 0
        elif [ "$MOCK_CASE" = webview_round_uid ] && [ "$(cat "$MOCK_STATE/round")" -ge 2 ]; then printf '%s\n' 10055
        else printf '%s\n' 10054; fi ;;
      *'stat -c %u /data/user/'*)
        if [ "$MOCK_CASE" = wrong_owner ] ||
            { [ "$MOCK_CASE" = webview_round_uid ] && [ "$(cat "$MOCK_STATE/round")" -ge 2 ]; }; then
          printf '%s\n' 10055
        else printf '%s\n' 10054; fi ;;
      *'pm install -t '*) [ "$MOCK_CASE" != install_failure ]; printf '%s\n' Success ;;
      *'am start -W '*)
        rm -f "$MOCK_STATE/stopped"
        count=0; if [ -f "$MOCK_STATE/round" ]; then count=$(cat "$MOCK_STATE/round"); fi
        printf '%s\n' "$((count + 1))" >"$MOCK_STATE/round"
        if [ "$MOCK_CASE" = webview_round_interrupted ]; then kill -TERM "$PPID"; exit 1; fi
        printf '%s\n' 'Status: ok' 'Activity: org.royd.tlsprobe/.TlsProbe'
        if [ "$MOCK_CASE" = webview_round_warm ]; then printf '%s\n' 'LaunchState: WARM'; else printf '%s\n' 'LaunchState: COLD'; fi ;;
      *'test -s '*) [ "$MOCK_CASE" != no_result ] ;;
      *'cat /data/user/'*)
        raw='{"uid":10054,"done":true,"url":"https://www.google.com/generate_204","untrusted_url":"https://172.17.0.1:43210/reject","active_network":"100","active_interface":"eth0","configured_dns":["127.0.0.11"],"default_callback_available":1,"dns_answers":["142.250.1.1"],"public_https":"pass","http_status":204,"cipher_suite":"TLS_AES_256_GCM_SHA384","peer_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","peer_subject":"CN=www.google.com","peer_issuer":"CN=issuer","body_bytes":0,"body_sha256":"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855","untrusted_rejected":true,"untrusted_causes":["javax.net.ssl.SSLHandshakeException","java.security.cert.CertPathValidatorException"]}'
        case "$MOCK_CASE" in webview*)
          raw=${raw%?}',"webview_url":"https://www.iana.org/help/example-domains","webview_untrusted_url":"https://172.17.0.1:43210/reject","webview_provider_package":"com.android.webview","webview_provider_version":"test","webview_user_agent":"Android; wv)","webview_certificate_subject":"CN=www.iana.org","webview_certificate_issuer":"CN=issuer","webview_committed":true,"webview_visual_state":true,"webview_untrusted_rejected":true,"webview_untrusted_cancelled":true,"webview_untrusted_has_authority_error":true,"webview_untrusted_primary_error":3,"webview_untrusted_error_url":"https://172.17.0.1:43210/reject","webview_dom":{"url":"https://www.iana.org/help/example-domains","title":"Example Domains","heading":"Example Domains","secure":true,"ready":"complete"}}'
        ;; esac
        case "$MOCK_CASE" in webview_round*)
          name=$(printf 'round-%03d.json' "$(cat "$MOCK_STATE/round")")
          if [ "$MOCK_CASE" = webview_round_stale ] && [ "$(cat "$MOCK_STATE/round")" -ge 2 ]; then name=round-001.json; fi
          raw=${raw%?}',"result_name":"'"$name"'"}'
          if [ "$(cat "$MOCK_STATE/round")" -ge 2 ]; then
            case "$MOCK_CASE" in
              webview_round_public_failure) raw=$(printf '%s\n' "$raw" | sed 's/"public_https":"pass"/"public_https":"fail"/') ;;
              webview_round_trust_failure) raw=$(printf '%s\n' "$raw" | sed 's/"webview_untrusted_cancelled":true/"webview_untrusted_cancelled":false/') ;;
            esac
          fi ;;
        esac
        case "$MOCK_CASE" in
          public_failure|both_failures) printf '%s\n' "$raw" | sed 's/"public_https":"pass"/"public_https":"fail"/' ;;
          trust_failure) printf '%s\n' "$raw" | sed 's/"untrusted_rejected":true/"untrusted_rejected":false/' ;;
          wrong_uid) printf '%s\n' "$raw" | sed 's/10054/10055/' ;;
          webview_document_failure) printf '%s\n' "$raw" | sed 's/"heading":"Example Domains"/"heading":"Wrong"/' ;;
          webview_trust_failure) printf '%s\n' "$raw" | sed 's/"webview_untrusted_cancelled":true/"webview_untrusted_cancelled":false/' ;;
          *) printf '%s\n' "$raw" ;;
        esac ;;
      *'ip -o -4 addr show dev eth0;'*)
        printf '%s\n' '2: eth0 inet 172.17.0.2/16 scope global' 'default via 172.17.0.1 dev eth0'
        if { [ "$MOCK_CASE" = ownership_changed ] && [ "$(cat "$MOCK_STATE/asserts")" = 2 ]; } ||
            { [ "$MOCK_CASE" = webview_round_oci ] && [ "$(cat "$MOCK_STATE/round")" -ge 2 ]; }; then printf '%s\n' changed; fi ;;
      *'input keyevent KEYCODE_WAKEUP'|*'wm dismiss-keyguard') exit 0 ;;
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
    server_changed start_failure capture_failure remote existing_container existing_volume existing_network existing_evidence bad_url \
    webview_good webview_private webview_document_failure webview_trust_failure webview_bad_target webview_bad_title \
    webview_round_good webview_round_private webview_round_stale webview_round_public_failure webview_round_trust_failure \
    webview_round_server webview_round_uid webview_round_restart webview_round_oom webview_round_stopped \
    webview_round_auto_restart webview_round_oci webview_round_stop_failure webview_round_pid_error webview_round_interrupted webview_round_warm; do
  state=$tmp/$mode
  mkdir "$state"
  printf '%s\n' 0 >"$state/asserts"
  if [ "$mode" = existing_evidence ]; then mkdir "$state/evidence"; : >"$state/evidence/preserve"; fi
  network_mode=bridge
  case "$mode" in private|existing_network|webview_private|webview_round_private) network_mode=private ;; esac
  rounds=1
  case "$mode" in webview_round*) rounds=3 ;; esac
  webview=0
  webview_target=https://www.iana.org/help/example-domains
  webview_title='Example Domains'
  # Empty overrides exercise the actual defaults in both successful DNS modes.
  case "$mode" in webview_good|webview_private) webview_target=; webview_title= ;; esac
  case "$mode" in webview*) webview=1 ;; esac
  if [ "$mode" = webview_bad_target ]; then webview_target=http://example.com/; fi
  if [ "$mode" = webview_bad_title ]; then webview_title='bad=title'; fi
  target=https://www.google.com/generate_204
  if [ "$mode" = bad_url ]; then target=http://invalid.test/; fi
  status=0
  PATH="$tmp/bin:$PATH" MOCK_CASE="$mode" MOCK_STATE="$state" MOCK_TOOLS="$tmp/bin" MOCK_HELPER="$tmp/helper" \
    ROYD_NETWORK_TLS_OUTPUT_DIR="$state/evidence" ROYD_NETWORK_TLS_NETWORK_MODE="$network_mode" \
    ROYD_NETWORK_TLS_WEBVIEW="$webview" ROYD_NETWORK_TLS_WEBVIEW_URL="$webview_target" ROYD_NETWORK_TLS_WEBVIEW_TITLE="$webview_title" \
    ROYD_NETWORK_TLS_ROUNDS="$rounds" ROYD_NETWORK_TLS_INTERVAL=0 \
    ROYD_NETWORK_TLS_URL="$target" ROYD_NETWORK_TLS_REQUEST_TIMEOUT=2 \
    ROYD_NETWORK_TLS_BUILD_RUNNER="$tmp/bin/build" ROYD_NETWORK_TLS_ASSERT_RUNNER="$tmp/bin/assert" \
    ROYD_NETWORK_TLS_WAIT_RUNNER="$tmp/bin/wait" ROYD_NETWORK_TLS_HEALTH_RUNNER="$tmp/bin/pass" \
    ROYD_NETWORK_TLS_SECURITY_RUNNER="$tmp/bin/pass" \
    "$script_dir/network-tls-test.sh" royd:test >"$state/result.log" 2>&1 || status=$?
  case "$mode" in
    webview_round_good|webview_round_private)
      [ "$status" -eq 0 ] || { cat "$state/result.log" "$state/docker.log"; exit 1; }
      grep -Fxq ROYD_NETWORK_TLS_EVIDENCE_FORMAT=3 "$state/evidence/manifest.env"
      grep -Fxq COMPLETED_ROUNDS=3 "$state/evidence/manifest.env"
      grep -Fxq ROUND_RESULTS_STATUS=pass "$state/evidence/manifest.env"
      grep -Fxq RESULT_STATUS=pass "$state/evidence/manifest.env"
      [ "$(cat "$state/asserts")" = 2 ]
      for round in 001 002 003; do
        grep -Fxq RESULT_STATUS=pass "$state/evidence/rounds/$round/manifest.env"
        grep -Fxq WEBVIEW_DOCUMENT_STATUS=pass "$state/evidence/rounds/$round/assessment.env"
        grep -Fxq WEBVIEW_UNTRUSTED_CERT_STATUS=pass "$state/evidence/rounds/$round/assessment.env"
        grep -Fq -- "--es result_name round-$round.json" "$state/docker.log"
      done ;;
    good|private|webview_good|webview_private)
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
    webview_round*)
      if [ "$status" -ne 0 ]; then
        grep -Fxq ROUND_RESULTS_STATUS=fail "$state/evidence/manifest.env"
        ! grep -Fxq RESULT_STATUS=pass "$state/evidence/rounds/002/manifest.env" 2>/dev/null
      fi ;;
    webview_good|webview_private)
      grep -Fxq ROYD_NETWORK_TLS_EVIDENCE_FORMAT=2 "$state/evidence/manifest.env"
      grep -Fxq WEBVIEW_DOCUMENT_STATUS=pass "$state/evidence/manifest.env"
      grep -Fxq WEBVIEW_UNTRUSTED_CERT_STATUS=pass "$state/evidence/manifest.env"
      grep -Fxq 'WEBVIEW_URL=https://www.iana.org/help/example-domains' "$state/evidence/manifest.env"
      grep -Fxq 'WEBVIEW_EXPECTED_TITLE=Example Domains' "$state/evidence/manifest.env"
      grep -Fq -- '--es webview_url https://www.iana.org/help/example-domains' "$state/docker.log" ;;
    webview_document_failure|webview_trust_failure)
      [ "$(cat "$state/asserts")" = 2 ]
      grep -Fxq RUNTIME_STATUS=pass "$state/evidence/manifest.env"
      if [ "$mode" = webview_document_failure ]; then field=WEBVIEW_DOCUMENT; else field=WEBVIEW_UNTRUSTED_CERT; fi
      grep -Fxq "${field}_STATUS=fail" "$state/evidence/manifest.env" ;;
    webview_bad_target|webview_bad_title)
      if grep -Eq '^(create|volume create) ' "$state/docker.log"; then exit 1; fi ;;
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
for setting in 'ROYD_NETWORK_TLS_ROUNDS=0' 'ROYD_NETWORK_TLS_ROUNDS=101' 'ROYD_NETWORK_TLS_ROUNDS=01' \
    'ROYD_NETWORK_TLS_ROUNDS=x' 'ROYD_NETWORK_TLS_INTERVAL=-1' 'ROYD_NETWORK_TLS_INTERVAL=301' 'ROYD_NETWORK_TLS_INTERVAL=00'; do
  state=$tmp/invalid-$(printf '%s' "$setting" | tr '=/' '__')
  mkdir "$state"
  status=0
  env "$setting" ROYD_NETWORK_TLS_OUTPUT_DIR="$state/evidence" "$script_dir/network-tls-test.sh" royd:test >"$state/result.log" 2>&1 || status=$?
  [ "$status" -eq 2 ]
  [ ! -e "$state/evidence" ]
done
printf '%s\n' 'Android 15 public DNS and HTTPS contract test passed'
