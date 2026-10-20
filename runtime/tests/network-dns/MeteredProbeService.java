package org.royd.networkprobe;

import android.app.ActivityManager;
import android.app.Service;
import android.content.Intent;
import android.net.ConnectivityManager;
import android.net.LinkProperties;
import android.net.Network;
import android.os.IBinder;
import android.os.Process;
import android.os.SystemClock;
import android.util.Log;
import java.io.ByteArrayOutputStream;
import java.io.DataOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.net.HttpURLConnection;
import java.net.InetAddress;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.concurrent.atomic.AtomicInteger;
import org.json.JSONArray;
import org.json.JSONObject;

/** Disposable ordinary-UID background service, never a product or foreground service. */
public final class MeteredProbeService extends Service {
    @Override public IBinder onBind(Intent intent) { return null; }

    private void publish(String name, JSONObject result) throws Exception {
        try (FileOutputStream output = openFileOutput(name + ".tmp", MODE_PRIVATE)) {
            output.write(result.toString().getBytes(StandardCharsets.UTF_8));
        }
        if (!new File(getFilesDir(), name + ".tmp").renameTo(new File(getFilesDir(), name + ".json"))) {
            throw new java.io.IOException("could not publish complete metered observation");
        }
    }

    private static int importance() {
        ActivityManager.RunningAppProcessInfo info = new ActivityManager.RunningAppProcessInfo();
        ActivityManager.getMyMemoryState(info);
        return info.importance;
    }

    private static String http(URL url) throws Exception {
        HttpURLConnection connection = (HttpURLConnection) url.openConnection();
        connection.setConnectTimeout(3000); connection.setReadTimeout(3000);
        connection.setUseCaches(false); connection.setInstanceFollowRedirects(false);
        connection.setRequestProperty("Connection", "close");
        try (InputStream input = connection.getInputStream()) {
            byte[] body = input.readNBytes(8193);
            String nonce = url.getPath().substring(url.getPath().lastIndexOf('/') + 1);
            return body.length <= 8192 && connection.getResponseCode() == 200
                    && new String(body, StandardCharsets.UTF_8).contains(nonce) ? "pass" : "bad-response";
        } finally { connection.disconnect(); }
    }

    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        new Thread(() -> {
            JSONObject result = new JSONObject();
            ConnectivityManager cm = getSystemService(ConnectivityManager.class);
            AtomicInteger available = new AtomicInteger();
            ConnectivityManager.NetworkCallback callback = new ConnectivityManager.NetworkCallback() {
                @Override public void onAvailable(Network network) { available.incrementAndGet(); }
            };
            try {
                String host = intent.getStringExtra("host");
                InetAddress server = InetAddress.getByName(intent.getStringExtra("dns"));
                URL url = new URL(intent.getStringExtra("url"));
                if (!host.equals("royd-probe.test") || !url.getProtocol().equals("http")
                        || !url.getHost().equals(server.getHostAddress()) || !server.isSiteLocalAddress()) {
                    throw new IllegalArgumentException("private literal fixture required");
                }
                result.put("uid", Process.myUid()); result.put("pid", Process.myPid());
                result.put("url", url.toString());
                publish("ready", result);
                int expectedImportance = intent.getBooleanExtra("foreground", false)
                        ? ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND
                        : ActivityManager.RunningAppProcessInfo.IMPORTANCE_SERVICE;
                long deadline = SystemClock.elapsedRealtime() + 45000;
                while (!new File(getFilesDir(), "probe.trigger").exists()
                        || importance() != expectedImportance) {
                    if (SystemClock.elapsedRealtime() >= deadline) throw new java.io.IOException("background probe gate timed out");
                    Thread.sleep(100);
                }
                result.put("importance", importance());
                Network active = cm.getActiveNetwork();
                result.put("active_network", String.valueOf(active));
                result.put("network_count", cm.getAllNetworks().length);
                result.put("network_metered", cm.isActiveNetworkMetered());
                LinkProperties link = active == null ? null : cm.getLinkProperties(active);
                result.put("active_interface", link == null ? "" : link.getInterfaceName());
                JSONArray configured = new JSONArray();
                if (link != null) for (InetAddress address : link.getDnsServers()) configured.put(address.getHostAddress());
                result.put("configured_dns", configured);
                cm.registerDefaultNetworkCallback(callback);
                try (DatagramSocket socket = new DatagramSocket()) {
                    ByteArrayOutputStream bytes = new ByteArrayOutputStream();
                    DataOutputStream query = new DataOutputStream(bytes);
                    query.writeShort(0x4a31); query.writeShort(0x0100);
                    query.writeShort(1); query.writeShort(0); query.writeShort(0); query.writeShort(0);
                    for (String label : host.split("\\.")) {
                        byte[] value = label.getBytes(StandardCharsets.US_ASCII);
                        query.writeByte(value.length); query.write(value);
                    }
                    query.writeByte(0); query.writeShort(1); query.writeShort(1);
                    byte[] wire = bytes.toByteArray();
                    socket.connect(server, 53); socket.setSoTimeout(3000);
                    socket.send(new DatagramPacket(wire, wire.length));
                    DatagramPacket response = new DatagramPacket(new byte[512], 512);
                    socket.receive(response);
                    int length = response.getLength(); byte[] received = response.getData();
                    boolean valid = length == wire.length + 16 && received[0] == 0x4a && received[1] == 0x31
                            && (received[2] & 0x80) != 0 && (received[3] & 15) == 0 && received[7] == 1
                            && received[length - 14] == 0 && received[length - 13] == 1
                            && received[length - 6] == 0 && received[length - 5] == 4
                            && Arrays.equals(server.getAddress(), Arrays.copyOfRange(received, length - 4, length));
                    result.put("direct_udp_dns", valid ? "pass" : "invalid-response");
                } catch (Exception error) { result.put("direct_udp_dns", error.toString()); }
                try { result.put("literal_http", http(url)); }
                catch (Exception error) { result.put("literal_http", error.toString()); }
                JSONArray addresses = new JSONArray();
                try { for (InetAddress address : InetAddress.getAllByName(host)) addresses.put(address.getHostAddress()); }
                catch (Exception error) { result.put("lookup_error", error.toString()); }
                result.put("system_dns_addresses", addresses);
                try { result.put("hostname_http", http(new URL("http", host, url.getPort(), url.getFile()))); }
                catch (Exception error) { result.put("hostname_http", error.toString()); }
                Thread.sleep(2000);
                result.put("default_callback_available", available.get());
                result.put("importance_after", importance());
                result.put("done", true);
            } catch (Exception error) {
                try { result.put("probe_error", error.toString()); } catch (Exception ignored) { }
            } finally {
                try { cm.unregisterNetworkCallback(callback); } catch (Exception ignored) { }
            }
            try { publish("result", result); }
            catch (Exception error) { Log.e("RoydMeteredProbe", "could not persist result", error); }
            Log.i("RoydMeteredProbe", result.toString());
        }, "royd-metered-probe").start();
        return START_NOT_STICKY;
    }
}
