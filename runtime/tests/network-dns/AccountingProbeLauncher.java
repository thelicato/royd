package org.royd.networkprobe;

import android.app.Activity;
import android.content.Intent;
import android.os.Bundle;
import android.view.WindowManager;

/** Start the ordinary socket-owning service from a visible test activity. */
public final class AccountingProbeLauncher extends Activity {
    private boolean started;
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
    }
    @Override public void onWindowFocusChanged(boolean focused) {
        super.onWindowFocusChanged(focused);
        if (!focused || started) return;
        started = true;
        Intent service = new Intent(this, AccountingProbeService.class);
        service.putExtras(getIntent());
        startService(service);
        finishAndRemoveTask();
    }
}
