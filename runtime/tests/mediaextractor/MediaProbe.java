package org.royd.mediaprobe;

import android.app.Activity;
import android.content.res.AssetFileDescriptor;
import android.media.MediaPlayer;
import android.os.Bundle;
import android.os.Process;
import android.view.WindowManager;
import android.widget.TextView;
import org.json.JSONArray;
import org.json.JSONObject;
import java.io.File;
import java.io.FileOutputStream;
import java.io.PrintWriter;
import java.io.StringWriter;
import java.nio.charset.StandardCharsets;

/** Public MediaPlayer preparation from an own APK asset, without permissions. */
public final class MediaProbe extends Activity {
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        TextView view = new TextView(this);
        view.setText("Preparing the media fixture...");
        setContentView(view);
        new Thread(() -> observe(view), "royd-media-observer").start();
    }

    private void observe(TextView view) {
        JSONObject result = new JSONObject();
        try {
            result.put("uid", Process.myUid()).put("pid", Process.myPid());
            JSONArray rounds = new JSONArray();
            result.put("rounds", rounds);
            for (int round = 1; round <= 5; ++round) {
                MediaPlayer player = new MediaPlayer();
                try (AssetFileDescriptor source = getAssets().openFd("probe.wav")) {
                    player.setDataSource(source.getFileDescriptor(), source.getStartOffset(), source.getLength());
                    player.prepare();
                    JSONArray tracks = new JSONArray();
                    for (MediaPlayer.TrackInfo track : player.getTrackInfo()) {
                        tracks.put(new JSONObject().put("type", track.getTrackType()));
                    }
                    rounds.put(new JSONObject().put("round", round).put("duration_ms", player.getDuration())
                            .put("tracks", tracks));
                } finally {
                    player.release();
                }
            }
            result.put("status", "pass");
        } catch (Exception failure) {
            StringWriter trace = new StringWriter();
            failure.printStackTrace(new PrintWriter(trace));
            try { result.put("status", "fail").put("error", trace.toString()); }
            catch (Exception ignored) { throw new IllegalStateException(failure); }
        }
        try {
            result.put("done", true);
            File target = new File(getFilesDir(), "result.json");
            File temporary = new File(getFilesDir(), "result.tmp");
            if (target.exists() || temporary.exists()) throw new IllegalStateException("result already exists");
            try (FileOutputStream stream = new FileOutputStream(temporary)) {
                stream.write(result.toString().getBytes(StandardCharsets.UTF_8));
            }
            if (!temporary.renameTo(target)) throw new IllegalStateException("result rename failed");
            runOnUiThread(() -> view.setText(result.toString()));
        } catch (Exception failure) { throw new IllegalStateException(failure); }
    }
}
