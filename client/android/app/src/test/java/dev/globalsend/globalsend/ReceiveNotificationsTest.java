package dev.globalsend.globalsend;

import static org.junit.Assert.*;
import android.app.Notification;
import android.app.NotificationManager;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ActivityInfo;
import android.content.pm.ApplicationInfo;
import android.content.pm.ResolveInfo;
import java.util.ArrayList;
import java.util.List;
import java.util.function.Consumer;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;
import org.robolectric.Shadows;
import org.robolectric.annotation.Config;

@RunWith(RobolectricTestRunner.class)
@Config(sdk = 28, manifest = Config.NONE)
public class ReceiveNotificationsTest {
    private Context context;
    private ReceiveNotifications notices;
    private NotificationManager manager;
    private FakePresenter presenter;
    private static class FakePresenter implements ReceiveNotifications.Presenter {
        final List<ReceiveNotifications.Receipt> receipts = new ArrayList<>();
        final List<Consumer<Boolean>> acknowledgements = new ArrayList<>();
        int hidden;
        public void show(ReceiveNotifications.Receipt receipt, long generation, Consumer<Boolean> shown) {
            receipts.add(receipt); acknowledgements.add(shown);
        }
        public void hide() { hidden++; }
    }
    @Before public void setup() {
        context = RuntimeEnvironment.getApplication();
        ResolveInfo launcher = new ResolveInfo();
        launcher.activityInfo = new ActivityInfo();
        launcher.activityInfo.packageName = context.getPackageName();
        launcher.activityInfo.name = "test.NotificationActivity";
        launcher.activityInfo.applicationInfo = new ApplicationInfo();
        launcher.activityInfo.applicationInfo.packageName = context.getPackageName();
        Shadows.shadowOf(context.getPackageManager()).addResolveInfoForIntent(
            new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER).setPackage(context.getPackageName()), launcher);
        presenter = new FakePresenter();
        notices = new ReceiveNotifications(context, presenter);
        notices.clear(); notices.setScope("group-a");
        notices.setPopupEnabled(false);
        org.robolectric.shadows.ShadowSettings.setCanDrawOverlays(true);
        manager = context.getSystemService(NotificationManager.class);
    }
    private Notification current() {
        List<Notification> all = Shadows.shadowOf(manager).getAllNotifications();
        return all.get(all.size() - 1);
    }
    private void receive(String id, String version, String text) throws Exception {
        notices.show("group-a", "sender", id, version, "电脑", text, null, false, "receive");
    }
    private void deadline() {
        Shadows.shadowOf(android.os.Looper.getMainLooper()).idleFor(java.time.Duration.ofSeconds(1));
    }
    @Test @Config(sdk=34) public void turningDockOffHidesCurrentWindowAndUsesNotificationForNextArrival() throws Exception {
        Shadows.shadowOf(RuntimeEnvironment.getApplication()).grantPermissions(android.Manifest.permission.POST_NOTIFICATIONS);
        notices.setPopupEnabled(true);receive("first","1","one");
        int before=presenter.hidden;
        notices.setPopupEnabled(false);
        assertEquals(before+1,presenter.hidden);
        receive("second","1","two");
        assertEquals(1,presenter.receipts.size());
        assertFalse(Shadows.shadowOf(manager).getAllNotifications().isEmpty());
    }

    @Test public void headsUpRequiresAnEnabledHighImportanceChannel() {
        assertTrue(notices.headsUpAllowed());
        manager.deleteNotificationChannel(ReceiveNotifications.CHANNEL);
        manager.createNotificationChannel(new android.app.NotificationChannel(
            ReceiveNotifications.CHANNEL, "收到的内容", NotificationManager.IMPORTANCE_LOW));
        assertFalse(notices.headsUpAllowed());
    }
    @Test @Config(sdk=34) public void updateKeepsOneNoticeAndOldCopyActionReadsFullLatestText() throws Exception {
        Shadows.shadowOf(RuntimeEnvironment.getApplication()).grantPermissions(android.Manifest.permission.POST_NOTIFICATIONS);
        receive("message", "1", "第一版");
        Notification old = current();
        String latest = "完整正文\n" + "长文字".repeat(4000);
        receive("message", "2", latest);
        assertEquals(1, Shadows.shadowOf(manager).getAllNotifications().size());
        assertTrue(notices.copy(Shadows.shadowOf(old.actions[0].actionIntent).getSavedIntent()));
        assertEquals(latest, context.getSystemService(ClipboardManager.class).getPrimaryClip().getItemAt(0).getText().toString());
        assertEquals("已复制",org.robolectric.shadows.ShadowToast.getTextOfLatestToast());
        assertFalse(notices.show("group-a", "sender", "message", "2", "电脑", latest, null, true, "receive"));
    }
    @Test public void fileNoticeOpensExactItemWithoutCopyAction() throws Exception {
        notices.show("group-a", "sender", "file", "received", "电脑", null, "照片.png", false, "receive");
        Notification notification = current();
        assertTrue(notification.actions == null || notification.actions.length == 0);
        Intent open = Shadows.shadowOf(notification.contentIntent).getSavedIntent();
        assertEquals("receive:file", notices.captureOpen(open));
        assertEquals("receive:file", new ReceiveNotifications(context, presenter).consumeOpen());
        assertEquals("", notices.consumeOpen());
        assertNotEquals(0, open.getFlags() & Intent.FLAG_ACTIVITY_SINGLE_TOP);
    }
    @Test public void restartKeepsCopyButGroupChangeClearsOldNoticeAndOverlay() throws Exception {
        receive("message", "1", "保留正文");
        Intent copy = Shadows.shadowOf(current().actions[0].actionIntent).getSavedIntent();
        ReceiveNotifications restarted = new ReceiveNotifications(context, presenter);
        restarted.setScope("group-a");
        assertTrue(restarted.copy(copy));
        int before = presenter.hidden;
        restarted.setScope("group-b");
        assertTrue(presenter.hidden > before);
        assertTrue(Shadows.shadowOf(manager).getAllNotifications().isEmpty());
        assertFalse(restarted.copy(copy));
        assertFalse(restarted.show("group-a", "sender", "message", "2", "电脑", "旧组", null, true, "receive"));
    }
    @Test public void attachedOverlaySuppressesFallbackWithoutStartingAnActivity() throws Exception {
        notices.setPopupEnabled(true);
        receive("message", "1", "正文");
        assertEquals(1, presenter.receipts.size());
        assertTrue(Shadows.shadowOf(manager).getAllNotifications().isEmpty());
        assertNull(Shadows.shadowOf((android.app.Application) context).getNextStartedActivity());
        presenter.acknowledgements.get(0).accept(true);
        deadline();
        assertTrue(Shadows.shadowOf(manager).getAllNotifications().isEmpty());
    }
    @Test public void addViewWithoutFirstDrawStillFallsBack() throws Exception {
        notices.setPopupEnabled(true);
        receive("message", "1", "正文");
        deadline();
        assertEquals(1, Shadows.shadowOf(manager).getAllNotifications().size());
        assertNull(current().fullScreenIntent);
        assertEquals(Notification.CATEGORY_MESSAGE, current().category);
    }
    @Test public void rejectedOverlayFallsBackAndNeverLaunchesFullscreen() throws Exception {
        notices.setPopupEnabled(true);
        receive("message", "1", "正文");
        presenter.acknowledgements.get(0).accept(false);
        deadline();
        assertEquals(1, Shadows.shadowOf(manager).getAllNotifications().size());
        assertNull(Shadows.shadowOf((android.app.Application) context).getNextStartedActivity());
    }
    @Test public void staleSuccessCannotAcknowledgeNewVersion() throws Exception {
        notices.setPopupEnabled(true);
        receive("message", "1", "旧");
        presenter.acknowledgements.get(0).accept(true);
        receive("message", "2", "新");
        presenter.acknowledgements.get(0).accept(true);
        deadline();
        assertEquals(1, Shadows.shadowOf(manager).getAllNotifications().size());
        assertEquals("新", current().extras.getCharSequence(Notification.EXTRA_TEXT).toString());
    }
    @Test public void filePresentationReceivesFinalLocalPathAndSize() throws Exception {
        notices.setPopupEnabled(true);
        notices.show("group-a", "sender", "file", "offered", "电脑", null, "照片.png", false, "receive", "", 24);
        notices.show("group-a", "sender", "file", "received", "电脑", null, "照片.png", true, "receive", "content://received/photo", 24);
        ReceiveNotifications.Receipt latest = presenter.receipts.get(1);
        assertEquals("content://received/photo", latest.localPath);
        assertEquals(24, latest.size);
    }
    @Test public void foregroundKeepsReceivePageAndRetiresOverlay() throws Exception {
        notices.setPopupEnabled(true);
        int before = presenter.hidden;
        notices.setForeground(true);
        receive("message", "1", "前台");
        assertTrue(presenter.hidden > before);
        assertTrue(presenter.receipts.isEmpty());
        assertTrue(Shadows.shadowOf(manager).getAllNotifications().isEmpty());
    }
    @Test public void permissionMissingUsesNoticeInsteadOfOverlay() throws Exception {
        notices.setPopupEnabled(true);
        org.robolectric.shadows.ShadowSettings.setCanDrawOverlays(false);
        assertFalse(notices.popupAllowed());
        receive("message", "1", "正文");
        assertTrue(presenter.receipts.isEmpty());
        assertNotNull(current().contentIntent);
    }
    @Test public void newArrivalInvalidatesStaleCloseAndSharedEditorStaysSilent() throws Exception {
        notices.setForeground(true);
        receive("one", "1", "一");
        long first = notices.arrivalGeneration();
        receive("two", "1", "二");
        long second = notices.arrivalGeneration();
        java.util.concurrent.atomic.AtomicInteger closed = new java.util.concurrent.atomic.AtomicInteger();
        assertTrue(notices.dismissIfCurrent(first, () -> { closed.incrementAndGet(); return true; }));
        assertEquals(0, closed.get());
        assertTrue(notices.dismissIfCurrent(second, () -> { closed.incrementAndGet(); return true; }));
        assertEquals(1, closed.get());
        assertFalse(notices.show("group-a", "shared", "shared", "1", "共享", "静默", null, true, "shared"));
        assertEquals(second, notices.arrivalGeneration());
    }
    @Test public void eachItemKeepsIndependentActionsAcrossEdits() throws Exception {
        receive("first", "1", "第一条");
        Notification first = current();
        receive("second", "1", "第二条");
        assertEquals(2, Shadows.shadowOf(manager).getAllNotifications().size());
        receive("first", "2", "第一条修改");
        assertEquals(2, Shadows.shadowOf(manager).getAllNotifications().size());
        assertEquals("receive:first", notices.captureOpen(Shadows.shadowOf(first.contentIntent).getSavedIntent()));
        assertTrue(notices.copy(Shadows.shadowOf(first.actions[0].actionIntent).getSavedIntent()));
        assertEquals("第一条修改", context.getSystemService(ClipboardManager.class).getPrimaryClip().getItemAt(0).getText().toString());
    }
}
