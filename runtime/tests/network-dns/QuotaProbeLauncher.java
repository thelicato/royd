package org.royd.networkprobe;

import android.app.Activity;
import android.content.Intent;
import android.os.Bundle;
import android.view.WindowManager;

/** Start one ordinary service after the visible activity has gained focus. */
public final class QuotaProbeLauncher extends Activity {
    private boolean started;
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
    }
    @Override public void onWindowFocusChanged(boolean focused) {
        super.onWindowFocusChanged(focused);
        if (!focused || started) return;
        started = true;
        Intent service = new Intent(this, QuotaProbeService.class);
        service.putExtras(getIntent());
        startService(service);
        finishAndRemoveTask();
    }
}
