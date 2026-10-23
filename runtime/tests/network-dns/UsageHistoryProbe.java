package org.royd.networkprobe;

import android.app.Activity;
import android.app.usage.NetworkStats;
import android.app.usage.NetworkStatsManager;
import android.net.ConnectivityManager;
import android.os.Bundle;
import android.os.Process;
import android.util.Log;
import android.view.WindowManager;
import android.widget.TextView;
import java.io.File;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import org.json.JSONObject;

/** Ordinary denied-other-UID query on an SDK-supported template, with no usage-access grant. */
public final class UsageHistoryProbe extends Activity {
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        TextView view = new TextView(this);
        view.setPadding(24, 160, 24, 24);
        setContentView(view);
        String label = getIntent().getStringExtra("label");
        if (label == null || !label.matches("[a-z0-9-]{1,32}")) {
            finish();
            return;
        }
        new Thread(() -> {
            JSONObject result = new JSONObject();
            try {
                int uid = Process.myUid();
                int queryUid = getIntent().getIntExtra("query_uid", uid);
                long end = getIntent().getLongExtra("query_end", 0);
                if (uid < 10000 || end <= System.currentTimeMillis()) {
                    throw new IllegalArgumentException("invalid query identity or interval");
                }
                result.put("label", label);
                result.put("uid", uid);
                result.put("query_uid", queryUid);
                result.put("query_start", 0);
                result.put("query_end", end);
                result.put("query_network_type", ConnectivityManager.TYPE_WIFI);
                long rx = 0, tx = 0, rxPackets = 0, txPackets = 0;
                int buckets = 0;
                try (NetworkStats stats = getSystemService(NetworkStatsManager.class)
                        .queryDetailsForUid(ConnectivityManager.TYPE_WIFI, null, 0, end, queryUid)) {
                    if (stats == null) throw new IllegalStateException("null history");
                    NetworkStats.Bucket bucket = new NetworkStats.Bucket();
                    while (stats.hasNextBucket()) {
                        if (!stats.getNextBucket(bucket) || bucket.getUid() != queryUid
                                || bucket.getRxBytes() < 0 || bucket.getTxBytes() < 0
                                || bucket.getRxPackets() < 0 || bucket.getTxPackets() < 0) {
                            throw new IllegalStateException("invalid history bucket");
                        }
                        rx = Math.addExact(rx, bucket.getRxBytes());
                        tx = Math.addExact(tx, bucket.getTxBytes());
                        rxPackets = Math.addExact(rxPackets, bucket.getRxPackets());
                        txPackets = Math.addExact(txPackets, bucket.getTxPackets());
                        buckets++;
                    }
                    result.put("status", "complete");
                    result.put("buckets", buckets);
                    result.put("rx_bytes", rx);
                    result.put("tx_bytes", tx);
                    result.put("rx_packets", rxPackets);
                    result.put("tx_packets", txPackets);
                } catch (SecurityException denied) {
                    result.put("status", "denied");
                    result.put("exception", denied.getClass().getName());
                }
                result.put("done", true);
            } catch (Exception error) {
                try { result.put("error", error.toString()); } catch (Exception ignored) { }
            }
            try {
                File temporary = new File(getFilesDir(), "history-" + label + ".tmp");
                File destination = new File(getFilesDir(), "history-" + label + ".json");
                if (destination.exists() || !temporary.createNewFile()) {
                    throw new IllegalStateException("history result already exists");
                }
                try (FileOutputStream file = new FileOutputStream(temporary)) {
                    file.write(result.toString().getBytes(StandardCharsets.UTF_8));
                }
                if (!temporary.renameTo(destination)) throw new IllegalStateException("publish failed");
            } catch (Exception error) { Log.e("RoydUsageHistory", "could not save observation", error); }
            Log.i("RoydUsageHistory", result.toString());
            runOnUiThread(() -> view.setText(result.toString()));
        }, "royd-usage-history").start();
    }
}
