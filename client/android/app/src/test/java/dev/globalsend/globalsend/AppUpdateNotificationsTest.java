package dev.globalsend.globalsend;

import static org.junit.Assert.*;
import android.Manifest;
import android.app.Application;
import android.app.Notification;
import android.app.NotificationManager;
import android.content.Intent;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;
import org.robolectric.Shadows;
import org.robolectric.annotation.Config;

@RunWith(RobolectricTestRunner.class)
@Config(sdk = 34, manifest = Config.NONE)
public class AppUpdateNotificationsTest {
    private Application app;
    private NotificationManager manager;
    @Before public void setup() {
        app = RuntimeEnvironment.getApplication();
        Shadows.shadowOf(app).grantPermissions(Manifest.permission.POST_NOTIFICATIONS);
        manager = app.getSystemService(NotificationManager.class);
    }
    @Test public void updateOpensGithubDownloadWithoutAReceivePopupOrFullScreenIntent() {
        String url = "https://github.com/DongLanQwQ0/GlobalSend/releases/download/v1.0.27/GlobalSend-1.0.27-android-arm64-v8a.apk";
        assertTrue(AppUpdateNotifications.show(app, "1.0.27", url));
        Notification notice = Shadows.shadowOf(manager).getNotification(AppUpdateNotifications.ID);
        assertEquals(AppUpdateNotifications.CHANNEL, notice.getChannelId());
        assertEquals(NotificationManager.IMPORTANCE_DEFAULT, manager.getNotificationChannel(notice.getChannelId()).getImportance());
        assertNull(notice.fullScreenIntent);
        Intent download = Shadows.shadowOf(notice.contentIntent).getSavedIntent();
        assertEquals(Intent.ACTION_VIEW, download.getAction());
        assertEquals(url, download.getDataString());
        assertNull(download.getComponent());
    }
    @Test public void disabledNotificationPermissionKeepsUpdatesInTheAppInstead() {
        Shadows.shadowOf(app).denyPermissions(Manifest.permission.POST_NOTIFICATIONS);
        assertFalse(AppUpdateNotifications.show(app, "1.0.27", "https://github.com/download.apk"));
        assertTrue(Shadows.shadowOf(manager).getAllNotifications().isEmpty());
    }
}
