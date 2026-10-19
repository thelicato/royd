package org.royd.networkprobe;

import android.app.Activity;
import android.net.ConnectivityManager;
import android.net.LinkProperties;
import android.net.Network;
import android.os.Bundle;
import android.os.Process;
import android.os.SystemClock;
import android.util.Log;
import android.widget.TextView;
import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.InetAddress;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.function.BooleanSupplier;
import org.json.JSONArray;
import org.json.JSONObject;

/** One ordinary process observing an externally controlled, container-local link cycle. */
public final class RecoveryProbe extends Activity {
    private final ArrayList<String> events = new ArrayList<>();
    private TextView text;

    private synchronized void event(String kind, Network network) {
        events.add(kind + ":" + network);
    }

    private synchronized boolean seen(String kind, String network) {
        return events.contains(kind + ":" + network);
    }

    private static void await(BooleanSupplier ready) throws Exception {
        long deadline = SystemClock.elapsedRealtime() + 45000;
        while (!ready.getAsBoolean()) {
            if (SystemClock.elapsedRealtime() >= deadline) throw new java.io.IOException("network transition timed out");
            Thread.sleep(100);
        }
    }

    private static String http(URL url) throws Exception {
        if (!url.getProtocol().equals("http")) throw new IllegalArgumentException("HTTP fixture required");
        HttpURLConnection connection = (HttpURLConnection) url.openConnection();
        connection.setConnectTimeout(3000);
        connection.setReadTimeout(3000);
        connection.setUseCaches(false);
        connection.setInstanceFollowRedirects(false);
        connection.setRequestProperty("Connection", "close");
        try (InputStream input = connection.getInputStream()) {
            byte[] bytes = input.readNBytes(8193);
            String nonce = url.getPath().substring(url.getPath().lastIndexOf('/') + 1);
            return bytes.length <= 8192 && connection.getResponseCode() == 200
                    && new String(bytes, StandardCharsets.UTF_8).contains(nonce) ? "pass" : "bad-response";
        } finally { connection.disconnect(); }
    }

    private JSONObject sample(ConnectivityManager cm, String phase, String host, URL url) throws Exception {
        JSONObject result = new JSONObject();
        result.put("phase", phase);
        result.put("uid", Process.myUid());
        result.put("pid", Process.myPid());
        result.put("elapsed_ms", SystemClock.elapsedRealtime());
        Network active = cm.getActiveNetwork();
        result.put("active_network", String.valueOf(active));
        LinkProperties link = active == null ? null : cm.getLinkProperties(active);
        result.put("active_interface", link == null ? "" : link.getInterfaceName());
        JSONArray dns = new JSONArray();
        if (link != null) for (InetAddress address : link.getDnsServers()) dns.put(address.getHostAddress());
        result.put("configured_dns", dns);
        result.put("url", url.toString());
        try { result.put("literal_http", http(url)); }
        catch (Exception error) {
            result.put("literal_http", "failed");
            result.put("literal_error", error.toString());
        }
        // No DNS timeout/cache assertion during intentional loss. Recovery uses a new name.
        if (!phase.equals("lost")) {
            result.put("host", host);
            JSONArray addresses = new JSONArray();
            try {
                for (InetAddress address : InetAddress.getAllByName(host)) addresses.put(address.getHostAddress());
                result.put("hostname_http", http(new URL("http", host, url.getPort(), url.getFile())));
            } catch (Exception error) { result.put("lookup_http_error", error.toString()); }
            result.put("system_dns_addresses", addresses);
        }
        synchronized (this) { result.put("events", new JSONArray(events)); }
        result.put("done", true);
        return result;
    }

    private void publish(String name, JSONObject result) throws Exception {
        try (FileOutputStream file = openFileOutput(name + ".tmp", MODE_PRIVATE)) {
            file.write(result.toString().getBytes(StandardCharsets.UTF_8));
        }
        if (!new File(getFilesDir(), name + ".tmp").renameTo(new File(getFilesDir(), name + ".json"))) {
            throw new java.io.IOException("could not publish recovery result");
        }
        Log.i("RoydNetworkRecovery", result.toString());
        runOnUiThread(() -> text.setText(result.toString()));
    }

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        text = new TextView(this);
        text.setPadding(24, 120, 24, 24);
        text.setTextColor(android.graphics.Color.BLACK);
        setContentView(text);
        new Thread(() -> {
            ConnectivityManager cm = getSystemService(ConnectivityManager.class);
            ConnectivityManager.NetworkCallback callback = new ConnectivityManager.NetworkCallback() {
                @Override public void onAvailable(Network network) { event("available", network); }
                @Override public void onLost(Network network) { event("lost", network); }
            };
            try {
                URL before = new URL(getIntent().getStringExtra("url"));
                URL after = new URL(getIntent().getStringExtra("recovery_url"));
                cm.registerDefaultNetworkCallback(callback);
                await(() -> cm.getActiveNetwork() != null && seen("available", String.valueOf(cm.getActiveNetwork())));
                String original = String.valueOf(cm.getActiveNetwork());
                JSONObject baseline = sample(cm, "baseline", "royd-probe.test", before);
                publish("baseline", baseline);
                await(() -> cm.getActiveNetwork() == null && seen("lost", original));
                JSONObject lost = sample(cm, "lost", "", before);
                publish("lost", lost);
                await(() -> cm.getActiveNetwork() != null && !original.equals(String.valueOf(cm.getActiveNetwork()))
                        && seen("available", String.valueOf(cm.getActiveNetwork())));
                JSONObject recovered = sample(cm, "recovered", "recovery.royd-probe.test", after);
                publish("recovered", recovered);
            } catch (Exception error) {
                Log.e("RoydNetworkRecovery", "recovery failed", error);
                try { publish("error", new JSONObject().put("error", error.toString())); }
                catch (Exception failure) { Log.e("RoydNetworkRecovery", "could not persist failure", failure); }
            } finally {
                try { cm.unregisterNetworkCallback(callback); } catch (Exception ignored) { }
            }
        }, "royd-network-recovery").start();
    }
}
