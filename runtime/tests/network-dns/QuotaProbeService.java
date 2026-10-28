package org.royd.networkprobe;

import android.app.Service;
import android.content.Intent;
import android.os.IBinder;
import android.util.Log;
import java.io.File;
import org.json.JSONObject;

public final class QuotaProbeService extends Service {
    private boolean started;
    private String nonce, address;
    @Override public IBinder onBind(Intent intent) { return null; }
    @Override public synchronized int onStartCommand(Intent intent, int flags, int startId) {
        int refresh = intent.getIntExtra("refresh", 0);
        if (started) {
            try {
                if (refresh < 1 || refresh > 64 || !nonce.equals(intent.getStringExtra("nonce"))
                        || !address.equals(intent.getStringExtra("address"))) {
                    throw new IllegalArgumentException("service refresh identity");
                }
                QuotaProbe.publish(new File(getFilesDir(), "quota-" + nonce), "refresh-" + refresh,
                        new JSONObject().put("nonce", nonce).put("uid", android.os.Process.myUid())
                        .put("pid", android.os.Process.myPid()).put("refresh", refresh));
            } catch (Exception error) { throw new IllegalStateException("service refresh failed", error); }
            return START_NOT_STICKY;
        }
        if (refresh != 0) throw new IllegalStateException("cannot refresh a replaced service");
        started = true;
        nonce = intent.getStringExtra("nonce");
        address = intent.getStringExtra("address");
        new Thread(() -> {
            try {
                QuotaProbe.run(new File(getFilesDir(), "quota-" + nonce), address, nonce, true);
            } catch (Exception error) {
                Log.e("RoydQuotaProbe", "quota workload failed", error);
            } finally { stopSelf(); }
        }, "royd-quota").start();
        return START_NOT_STICKY;
    }
}
