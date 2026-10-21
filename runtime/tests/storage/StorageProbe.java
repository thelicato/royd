package org.royd.storageprobe;

import android.app.Activity;
import android.app.usage.StorageStatsManager;
import android.os.Bundle;
import android.os.Environment;
import android.os.Process;
import android.os.StatFs;
import android.os.storage.StorageManager;
import android.widget.TextView;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.File;
import java.io.FileOutputStream;
import java.io.PrintWriter;
import java.io.StringWriter;
import java.nio.charset.StandardCharsets;

/** Ordinary-UID public API observations, not a platform-signed or privileged client. */
public final class StorageProbe extends Activity {
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        TextView view = new TextView(this);
        view.setText("Reading storage capacity...");
        setContentView(view);
        int round = getIntent().getIntExtra("round", 0);
        if (round < 1 || round > 2) { finish(); return; }
        new Thread(() -> observe(round, view), "royd-storage-observer").start();
    }

    private void observe(int round, TextView view) {
        JSONObject result = new JSONObject();
        try {
            result.put("round", round).put("uid", Process.myUid()).put("pid", Process.myPid());
            JSONArray readings = new JSONArray();
            result.put("readings", readings);
            StorageStatsManager stats = getSystemService(StorageStatsManager.class);
            for (int i = 0; i < 3; i++) {
                StatFs fs = new StatFs(Environment.getDataDirectory().getAbsolutePath());
                readings.put(new JSONObject().put("filesystem_total", fs.getTotalBytes())
                        .put("filesystem_available", fs.getAvailableBytes())
                        .put("stats_total", stats.getTotalBytes(StorageManager.UUID_DEFAULT))
                        .put("stats_free", stats.getFreeBytes(StorageManager.UUID_DEFAULT)));
            }
            result.put("status", "pass");
        } catch (Exception failure) {
            // Test observation only: preserve the exact error and fail assessment, never
            // replace the platform result with a successful fallback.
            StringWriter trace = new StringWriter();
            failure.printStackTrace(new PrintWriter(trace));
            try { result.put("status", "fail").put("error", trace.toString()); }
            catch (Exception ignored) { throw new IllegalStateException(failure); }
        }
        try {
            result.put("done", true);
            File target = new File(getFilesDir(), "result-" + round + ".json");
            if (target.exists()) throw new IllegalStateException("result already exists");
            File temporary = new File(getFilesDir(), "result-" + round + ".tmp");
            try (FileOutputStream stream = new FileOutputStream(temporary)) {
                stream.write(result.toString().getBytes(StandardCharsets.UTF_8));
            }
            if (!temporary.renameTo(target)) throw new IllegalStateException("result rename failed");
            runOnUiThread(() -> view.setText(result.toString()));
        } catch (Exception failure) { throw new IllegalStateException(failure); }
    }
}
