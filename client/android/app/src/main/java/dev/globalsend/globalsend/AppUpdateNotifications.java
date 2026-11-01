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
        return show(context, version, downloadUrl, false, null);
    }
    static boolean show(Context context, String version, String downloadUrl, boolean ready, String path) {
        NotificationManager manager = context.getSystemService(NotificationManager.class);
        if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(new NotificationChannel(CHANNEL, "版本更新", NotificationManager.IMPORTANCE_DEFAULT));
        }
        if (Build.VERSION.SDK_INT >= 33 && context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return false;
        if (!manager.areNotificationsEnabled() || Build.VERSION.SDK_INT >= 26 && manager.getNotificationChannel(CHANNEL).getImportance() == NotificationManager.IMPORTANCE_NONE) return false;
        Intent download = ready
            ? new Intent().setClassName(context.getPackageName(), MainActivity.class.getName())
                .setAction("dev.globalsend.globalsend.OPEN_UPDATE")
                .putExtra("updateReady", true).putExtra("updatePath", path)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP | Intent.FLAG_ACTIVITY_CLEAR_TOP)
            : new Intent(Intent.ACTION_VIEW, Uri.parse(downloadUrl)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        PendingIntent open = PendingIntent.getActivity(context, ID, download, PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        Notification.Builder notice = Build.VERSION.SDK_INT >= 26 ? new Notification.Builder(context, CHANNEL) : new Notification.Builder(context);
        manager.notify(ID, notice.setSmallIcon(android.R.drawable.stat_sys_download_done)
            .setContentTitle(ready ? "GlobalSend 更新已下载" : "GlobalSend 有新版本")
            .setContentText(version + (ready ? " · 点按安装" : " 可更新"))
            .setContentIntent(open).setAutoCancel(true).setOnlyAlertOnce(true).build());
        return true;
    }
}
