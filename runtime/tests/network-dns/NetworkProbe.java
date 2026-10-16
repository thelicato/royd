package org.royd.networkprobe;

import android.app.Activity;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.LinkProperties;
import android.net.NetworkCapabilities;
import android.os.Bundle;
import android.os.Process;
import android.util.Log;
import android.widget.TextView;
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

/** Disposable test application, never a product package or a networking workaround. */
public final class NetworkProbe extends Activity {
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
                String host = getIntent().getStringExtra("host");
                String dns = getIntent().getStringExtra("dns");
                String url = getIntent().getStringExtra("url");
                result.put("uid", Process.myUid());
                result.put("active_network", String.valueOf(cm.getActiveNetwork()));
                result.put("network_count", cm.getAllNetworks().length);
                Network active = cm.getActiveNetwork();
                LinkProperties link = active == null ? null : cm.getLinkProperties(active);
                result.put("active_interface", link == null ? "" : link.getInterfaceName());
                JSONArray configuredDns = new JSONArray();
                if (link != null) for (InetAddress address : link.getDnsServers()) {
                    configuredDns.put(address.getHostAddress());
                }
                result.put("configured_dns", configuredDns);
                NetworkCapabilities caps = active == null ? null : cm.getNetworkCapabilities(active);
                result.put("internet_validated", caps != null
                        && caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED));
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
                    InetAddress server = InetAddress.getByName(dns);
                    socket.connect(server, 53); socket.setSoTimeout(3000);
                    socket.send(new DatagramPacket(wire, wire.length));
                    DatagramPacket response = new DatagramPacket(new byte[512], 512);
                    socket.receive(response);
                    int length = response.getLength();
                    byte[] received = response.getData();
                    boolean valid = length == wire.length + 16 && received[0] == 0x4a && received[1] == 0x31
                            && (received[2] & 0x80) != 0 && (received[3] & 15) == 0
                            && received[6] == 0 && received[7] == 1
                            && received[length - 14] == 0 && received[length - 13] == 1
                            && received[length - 12] == 0 && received[length - 11] == 1
                            && received[length - 6] == 0 && received[length - 5] == 4
                            && Arrays.equals(server.getAddress(), Arrays.copyOfRange(received, length - 4, length));
                    result.put("direct_udp_dns", valid ? "pass" : "invalid-response");
                } catch (Exception error) { result.put("direct_udp_dns", error.toString()); }
                try {
                    HttpURLConnection connection = (HttpURLConnection) new URL(url).openConnection();
                    connection.setConnectTimeout(3000); connection.setReadTimeout(3000);
                    try (InputStream input = connection.getInputStream()) {
                        String body = new String(input.readAllBytes(), StandardCharsets.UTF_8);
                        String nonce = new URL(url).getPath().substring(new URL(url).getPath().lastIndexOf('/') + 1);
                        result.put("literal_http", connection.getResponseCode() == 200 && body.contains(nonce) ? "pass" : "bad-response");
                    } finally { connection.disconnect(); }
                } catch (Exception error) { result.put("literal_http", error.toString()); }
                JSONArray addresses = new JSONArray();
                try {
                    for (InetAddress address : InetAddress.getAllByName(host)) addresses.put(address.getHostAddress());
                } catch (Exception error) {
                    result.put("lookup_error", error.toString());
                    Log.e("RoydNetworkProbe", "system DNS failed", error);
                }
                result.put("system_dns_addresses", addresses);
                try {
                    URL literal = new URL(url);
                    URL named = new URL(literal.getProtocol(), host, literal.getPort(), literal.getFile());
                    HttpURLConnection connection = (HttpURLConnection) named.openConnection();
                    connection.setConnectTimeout(3000); connection.setReadTimeout(3000);
                    try (InputStream input = connection.getInputStream()) {
                        String body = new String(input.readAllBytes(), StandardCharsets.UTF_8);
                        String nonce = literal.getPath().substring(literal.getPath().lastIndexOf('/') + 1);
                        result.put("hostname_http", connection.getResponseCode() == 200
                                && body.contains(nonce) ? "pass" : "bad-response");
                    } finally { connection.disconnect(); }
                } catch (Exception error) { result.put("hostname_http", error.toString()); }
                Thread.sleep(2000);
                result.put("default_callback_available", available.get());
                result.put("done", true);
            } catch (Exception error) {
                try { result.put("probe_error", error.toString()); } catch (Exception ignored) { }
            } finally {
                try { cm.unregisterNetworkCallback(callback); } catch (Exception ignored) { }
            }
            Log.i("RoydNetworkProbe", result.toString());
            try {
                try (FileOutputStream file = openFileOutput("result.tmp", MODE_PRIVATE)) {
                    file.write(result.toString().getBytes(StandardCharsets.UTF_8));
                }
                if (!new File(getFilesDir(), "result.tmp").renameTo(new File(getFilesDir(), "result.json"))) {
                    throw new java.io.IOException("could not publish complete result");
                }
            } catch (Exception error) { Log.e("RoydNetworkProbe", "could not persist result", error); }
            runOnUiThread(() -> text.setText(result.toString()));
        }, "royd-network-probe").start();
    }
}
