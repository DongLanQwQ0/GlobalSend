package dev.globalsend.globalsend;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/** Resume the user's existing receive session after reboot or app replacement. */
public final class BackgroundReceiveRestart extends BroadcastReceiver {
    @Override public void onReceive(Context context, Intent intent) {
        if (!BackgroundReceiveService.wanted(context)) return;
        try { BackgroundReceiveService.start(context); }
        catch (RuntimeException failure) {
            // The system may defer a foreground start; the next visible app
            // lifecycle retries without starting an alarm/restart loop.
            android.util.Log.w("GlobalSend", "Background receive will resume when the app is opened", failure);
        }
    }
}
