package org.royd.networkprobe;

import android.app.Activity;
import android.content.Intent;

/** Legitimate foreground start of an ordinary service, with no traffic in the activity. */
public final class MeteredProbeLauncher extends Activity {
    private boolean started;
    @Override public void onResume() {
        super.onResume();
        if (started) return;
        started = true;
        Intent service = new Intent(this, MeteredProbeService.class);
        service.putExtras(getIntent());
        startService(service);
        // The explicit foreground control keeps a real activity resumed, not a foreground service.
        if (!getIntent().getBooleanExtra("foreground", false)) finishAndRemoveTask();
    }
}
