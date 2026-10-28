package dev.globalsend.globalsend;

import android.Manifest;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Build;

/** Update notices are independent of received-content popups and foreground service. */
final class AppUpdateNotifications {
    static final String CHANNEL = "globalsend-updates";
    static final int ID = 7839;
    static boolean show(Context context, String version, String downloadUrl) {
        NotificationManager manager = context.getSystemService(NotificationManager.class);
        if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(new NotificationChannel(CHANNEL, "版本更新", NotificationManager.IMPORTANCE_DEFAULT));
        }
        if (Build.VERSION.SDK_INT >= 33 && context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return false;
        if (!manager.areNotificationsEnabled() || Build.VERSION.SDK_INT >= 26 && manager.getNotificationChannel(CHANNEL).getImportance() == NotificationManager.IMPORTANCE_NONE) return false;
        Intent download = new Intent(Intent.ACTION_VIEW, Uri.parse(downloadUrl)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        PendingIntent open = PendingIntent.getActivity(context, ID, download, PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        Notification.Builder notice = Build.VERSION.SDK_INT >= 26 ? new Notification.Builder(context, CHANNEL) : new Notification.Builder(context);
        manager.notify(ID, notice.setSmallIcon(android.R.drawable.stat_sys_download_done)
            .setContentTitle("GlobalSend 有新版本").setContentText(version + " 可更新")
            .setContentIntent(open).setAutoCancel(true).setOnlyAlertOnce(true).build());
        return true;
    }
}
