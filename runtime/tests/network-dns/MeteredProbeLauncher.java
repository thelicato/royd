package org.royd.networkprobe;

import android.app.Activity;
import android.content.Intent;
import android.os.Bundle;
import android.view.WindowManager;

/** Legitimate foreground start of an ordinary service, with no traffic in the activity. */
public final class MeteredProbeLauncher extends Activity {
    private boolean started;
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        // Keep only this visible window awake, not its background service.
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
    }
    @Override public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);
        // onResume can run while still asleep, before this window can request a wake.
        if (!hasFocus || started) return;
        started = true;
        Intent service = new Intent(this, MeteredProbeService.class);
        service.putExtras(getIntent());
        startService(service);
        // The explicit foreground control keeps a real activity resumed, not a foreground service.
        if (!getIntent().getBooleanExtra("foreground", false)) finishAndRemoveTask();
    }
}
