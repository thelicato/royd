package org.royd.tlsprobe;

import android.app.Activity;
import android.net.ConnectivityManager;
import android.net.LinkProperties;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.os.Bundle;
import android.os.Process;
import android.util.Log;
import android.widget.TextView;
import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.net.InetAddress;
import java.net.URL;
import java.security.MessageDigest;
import java.security.cert.CertificateException;
import java.security.cert.CertPathValidatorException;
import java.security.cert.X509Certificate;
import java.util.concurrent.atomic.AtomicInteger;
import javax.net.ssl.HttpsURLConnection;
import javax.net.ssl.SSLHandshakeException;
import org.json.JSONArray;
import org.json.JSONObject;

/** Ordinary test UID using platform DNS, HTTPS trust and hostname verification unchanged. */
public final class TlsProbe extends Activity {
    private static boolean isCertificateTrustFailure(Throwable error) {
        if (!(error instanceof SSLHandshakeException)) return false;
        for (Throwable cause = error; cause != null; cause = cause.getCause()) {
            if (cause instanceof CertificateException || cause instanceof CertPathValidatorException) return true;
        }
        return false;
    }

    private static String sha256(byte[] bytes) throws Exception {
        StringBuilder hex = new StringBuilder();
        for (byte value : MessageDigest.getInstance("SHA-256").digest(bytes)) {
            hex.append(String.format(java.util.Locale.ROOT, "%02x", value & 255));
        }
        return hex.toString();
    }

    private static HttpsURLConnection open(URL url) throws Exception {
        if (!url.getProtocol().equals("https")) throw new IllegalArgumentException("HTTPS required");
        HttpsURLConnection connection = (HttpsURLConnection) url.openConnection();
        connection.setConnectTimeout(10000);
        connection.setReadTimeout(10000);
        connection.setInstanceFollowRedirects(false);
        connection.setUseCaches(false);
        return connection;
    }

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        TextView text = new TextView(this);
        text.setPadding(24, 160, 24, 24);
        text.setTextColor(android.graphics.Color.BLACK);
        setContentView(text);
        new Thread(() -> {
            JSONObject result = new JSONObject();
            ConnectivityManager cm = getSystemService(ConnectivityManager.class);
            AtomicInteger available = new AtomicInteger();
            ConnectivityManager.NetworkCallback callback = new ConnectivityManager.NetworkCallback() {
                @Override public void onAvailable(Network network) { available.incrementAndGet(); }
            };
            try {
                URL target = new URL(getIntent().getStringExtra("url"));
                URL untrusted = new URL(getIntent().getStringExtra("untrusted"));
                result.put("uid", Process.myUid());
                result.put("url", target.toString());
                result.put("untrusted_url", untrusted.toString());
                Network active = cm.getActiveNetwork();
                result.put("active_network", String.valueOf(active));
                LinkProperties link = active == null ? null : cm.getLinkProperties(active);
                result.put("active_interface", link == null ? "" : link.getInterfaceName());
                JSONArray dns = new JSONArray();
                if (link != null) for (InetAddress address : link.getDnsServers()) {
                    dns.put(address.getHostAddress());
                }
                result.put("configured_dns", dns);
                NetworkCapabilities caps = active == null ? null : cm.getNetworkCapabilities(active);
                result.put("internet_validated", caps != null
                        && caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED));
                cm.registerDefaultNetworkCallback(callback);
                JSONArray answers = new JSONArray();
                try {
                    for (InetAddress address : InetAddress.getAllByName(target.getHost())) {
                        answers.put(address.getHostAddress());
                    }
                } catch (Exception error) { result.put("dns_error", error.toString()); }
                result.put("dns_answers", answers);
                HttpsURLConnection connection = open(target);
                try {
                    int status = connection.getResponseCode();
                    result.put("http_status", status);
                    result.put("cipher_suite", connection.getCipherSuite());
                    X509Certificate leaf = (X509Certificate) connection.getServerCertificates()[0];
                    result.put("peer_subject", leaf.getSubjectX500Principal().getName());
                    result.put("peer_issuer", leaf.getIssuerX500Principal().getName());
                    result.put("peer_sha256", sha256(leaf.getEncoded()));
                    MessageDigest body = MessageDigest.getInstance("SHA-256");
                    int count = 0;
                    try (InputStream input = connection.getInputStream()) {
                        byte[] buffer = new byte[4096];
                        int size;
                        while ((size = input.read(buffer)) != -1) {
                            count += size;
                            if (count > 65536) throw new java.io.IOException("response exceeds 64 KiB");
                            body.update(buffer, 0, size);
                        }
                    }
                    result.put("body_bytes", count);
                    StringBuilder digest = new StringBuilder();
                    for (byte value : body.digest()) digest.append(String.format(java.util.Locale.ROOT, "%02x", value & 255));
                    result.put("body_sha256", digest.toString());
                    result.put("public_https", "pass");
                } catch (Exception error) {
                    result.put("https_error", error.toString());
                } finally { connection.disconnect(); }
                connection = open(untrusted);
                try {
                    result.put("untrusted_http_status", connection.getResponseCode());
                    result.put("untrusted_rejected", false);
                } catch (Exception error) {
                    JSONArray causes = new JSONArray();
                    for (Throwable cause = error; cause != null; cause = cause.getCause()) {
                        causes.put(cause.getClass().getName());
                    }
                    result.put("untrusted_error", error.toString());
                    result.put("untrusted_causes", causes);
                    result.put("untrusted_rejected", isCertificateTrustFailure(error));
                } finally { connection.disconnect(); }
                Thread.sleep(2000);
                result.put("default_callback_available", available.get());
                result.put("done", true);
            } catch (Exception error) {
                try { result.put("probe_error", error.toString()); } catch (Exception ignored) { }
            } finally {
                try { cm.unregisterNetworkCallback(callback); } catch (Exception ignored) { }
            }
            Log.i("RoydTlsProbe", result.toString());
            try {
                try (FileOutputStream file = openFileOutput("result.tmp", MODE_PRIVATE)) {
                    file.write(result.toString().getBytes(java.nio.charset.StandardCharsets.UTF_8));
                }
                if (!new File(getFilesDir(), "result.tmp").renameTo(new File(getFilesDir(), "result.json"))) {
                    throw new java.io.IOException("could not publish complete result");
                }
            } catch (Exception error) { Log.e("RoydTlsProbe", "could not persist result", error); }
            runOnUiThread(() -> text.setText(result.toString()));
        }, "royd-tls-probe").start();
    }
}
