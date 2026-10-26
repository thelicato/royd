package org.royd.networkprobe;

import android.app.Activity;
import android.net.ConnectivityManager;
import android.os.Bundle;
import android.os.Process;
import android.util.Log;
import android.view.WindowManager;
import android.widget.TextView;
import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import org.json.JSONObject;

/** Own-UID HTTP seed for recorder persistence, without usage-access privileges. */
public final class HistorySeedProbe extends Activity {
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        TextView view = new TextView(this);
        setContentView(view);
        new Thread(() -> {
            JSONObject result = new JSONObject();
            try {
                URL url = new URL(getIntent().getStringExtra("url"));
                String nonce = url.getPath().substring(url.getPath().lastIndexOf('/') + 1);
                if (!"http".equals(url.getProtocol()) || !nonce.matches("[0-9a-f]{32}")) {
                    throw new IllegalArgumentException("invalid fixture URL");
                }
                ConnectivityManager cm = getSystemService(ConnectivityManager.class);
                result.put("uid", Process.myUid());
                result.put("pid", Process.myPid());
                result.put("url", url.toString());
                result.put("interface", cm.getLinkProperties(cm.getActiveNetwork()).getInterfaceName());
                HttpURLConnection connection = (HttpURLConnection) url.openConnection();
                connection.setConnectTimeout(5000);
                connection.setReadTimeout(5000);
                connection.setUseCaches(false);
                connection.setInstanceFollowRedirects(false);
                connection.setRequestProperty("Connection", "close");
                try (InputStream input = connection.getInputStream()) {
                    byte[] body = input.readAllBytes();
                    result.put("http_status", connection.getResponseCode());
                    result.put("body_bytes", body.length);
                    result.put("body_nonce", new String(body, StandardCharsets.UTF_8).contains(nonce));
                } finally { connection.disconnect(); }
                result.put("done", true);
            } catch (Exception error) {
                try { result.put("error", error.toString()); } catch (Exception ignored) { }
            }
            try {
                File temporary = new File(getFilesDir(), "seed.tmp");
                File destination = new File(getFilesDir(), "seed.json");
                if (destination.exists() || !temporary.createNewFile()) {
                    throw new IllegalStateException("seed already exists");
                }
                try (FileOutputStream file = new FileOutputStream(temporary)) {
                    file.write(result.toString().getBytes(StandardCharsets.UTF_8));
                }
                if (!temporary.renameTo(destination)) throw new IllegalStateException("publish failed");
            } catch (Exception error) { Log.e("RoydHistorySeed", "could not save seed", error); }
            runOnUiThread(() -> view.setText(result.toString()));
        }, "royd-history-seed").start();
    }
}
