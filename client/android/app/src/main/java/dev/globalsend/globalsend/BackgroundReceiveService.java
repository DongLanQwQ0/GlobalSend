package dev.globalsend.globalsend;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.ServiceInfo;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.PowerManager;

/** Cross-device message continuity and peer-file reception, independent of UI. */
public final class BackgroundReceiveService extends Service {
    static final String PREFS = "globalsend-background-receive";
    static final String PAUSE = "dev.globalsend.PAUSE_RECEIVING";
    private static final String CHANNEL = "background-receive";
    private static final int NOTICE = 7843;
    static volatile BackgroundReceiveService current;
    private final Handler main = new Handler(Looper.getMainLooper());
    private PowerManager.WakeLock transferWake;
    private boolean transferring;
    private final Runnable renewTransferWake = new Runnable() {
        @Override public void run() {
            if (!transferring || current != BackgroundReceiveService.this) return;
            // A bounded lease is renewed only while the actual receive runtime
            // reports a file task. Idle message listening owns no CPU lock.
            transferWake.acquire(10 * 60 * 1000L);
            main.postDelayed(this, 60 * 1000L);
        }
    };
    static SharedPreferences preferences(Context context) { return context.getSharedPreferences(PREFS, MODE_PRIVATE); }
    static boolean wanted(Context context) {
        SharedPreferences p = preferences(context);
        return p.getBoolean("enabled", true) && p.getBoolean("authenticated", false);
    }
    static void start(Context context) {
        Intent intent = new Intent(context, BackgroundReceiveService.class);
        if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent); else context.startService(intent);
    }
    @Override public void onCreate() {
        super.onCreate();
        if (Build.VERSION.SDK_INT >= 26) getSystemService(NotificationManager.class).createNotificationChannel(
            new NotificationChannel(CHANNEL, "后台接收", NotificationManager.IMPORTANCE_LOW));
        transferWake = ((PowerManager) getSystemService(POWER_SERVICE)).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "GlobalSend:receiving-file");
        transferWake.setReferenceCounted(false);
    }
    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent != null && PAUSE.equals(intent.getAction())) {
            preferences(this).edit().putBoolean("enabled", false).commit();
            NativeReceiveRuntime runtime = NativeReceiveRuntime.current();
            if (runtime != null) runtime.background.pauseRequested();
            stopSelf(); return START_NOT_STICKY;
        }
        if (!wanted(this)) { stopSelf(); return START_NOT_STICKY; }
        Notification notice = notification("正在恢复接收");
        if (Build.VERSION.SDK_INT >= 34) startForeground(NOTICE, notice,
            ServiceInfo.FOREGROUND_SERVICE_TYPE_REMOTE_MESSAGING | ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE);
        else if (Build.VERSION.SDK_INT >= 29) startForeground(NOTICE, notice, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE);
        else startForeground(NOTICE, notice);
        current = this;
        NativeReceiveRuntime runtime = NativeReceiveRuntime.ensure(this);
        runtime.background.serviceChanged();
        return START_STICKY;
    }
    private Notification notification(String text) {
        PendingIntent open = PendingIntent.getActivity(this, 7843,
            new Intent(this, MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP | Intent.FLAG_ACTIVITY_CLEAR_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        PendingIntent pause = PendingIntent.getService(this, 7844, new Intent(this, BackgroundReceiveService.class).setAction(PAUSE),
            PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        Notification.Builder builder = Build.VERSION.SDK_INT >= 26 ? new Notification.Builder(this, CHANNEL) : new Notification.Builder(this);
        return builder.setSmallIcon(android.R.drawable.stat_notify_sync_noanim).setContentTitle("GlobalSend 后台接收")
            .setContentText(text).setCategory(Notification.CATEGORY_SERVICE).setOngoing(true).setOnlyAlertOnce(true)
            .setShowWhen(false).setContentIntent(open)
            .addAction(new Notification.Action.Builder(null, "暂停后台", pause).build()).build();
    }
    void update(boolean connected, boolean activeTransfer) {
        getSystemService(NotificationManager.class).notify(NOTICE,
            notification(connected ? activeTransfer ? "正在传输文件" : "已连接 · 可接收文字和文件" : "正在重新连接"));
        if (transferring == activeTransfer) return;
        transferring = activeTransfer; main.removeCallbacks(renewTransferWake);
        if (activeTransfer) renewTransferWake.run(); else if (transferWake.isHeld()) transferWake.release();
    }
    @Override public void onDestroy() {
        if (current == this) current = null;
        transferring = false; main.removeCallbacks(renewTransferWake);
        if (transferWake != null && transferWake.isHeld()) transferWake.release();
        NativeReceiveRuntime runtime = NativeReceiveRuntime.current();
        if (runtime != null) runtime.background.serviceChanged();
        super.onDestroy();
    }
    @Override public IBinder onBind(Intent intent) { return null; }
}
