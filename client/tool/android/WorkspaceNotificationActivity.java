package dev.globalsend.globalsend;

import android.app.Activity;
import android.app.Notification;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.ClipboardManager;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.os.Bundle;
import android.os.Handler;
import android.service.notification.StatusBarNotification;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;
import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import org.json.JSONArray;
import org.json.JSONObject;

/** Consumes production notification manager/receiver with synthetic local content. */
public final class WorkspaceNotificationActivity extends Activity {
    private ReceiveNotifications notices;
    private JSONObject result = new JSONObject();
    private File output;
    private TextView status;
    private PendingIntent oldCopy;
    private final Handler handler = new Handler();
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        try {
            output = new File(getExternalFilesDir("runtime-results"), "notification-result.json");
            if (output.isFile()) result = new JSONObject(new String(Files.readAllBytes(output.toPath()), StandardCharsets.UTF_8));
            notices = new ReceiveNotifications(this);
            LinearLayout page = new LinearLayout(this); page.setOrientation(LinearLayout.VERTICAL); page.setPadding(40, 70, 40, 40); page.setBackgroundColor(0xfff2f5f1); setContentView(page);
            TextView title = new TextView(this); title.setText("GlobalSend · 聊天通知运行检查"); title.setTextSize(23); page.addView(title);
            Button post = new Button(this); post.setText("允许通知并发布测试消息"); page.addView(post);
            post.setOnClickListener(view -> {
                if (android.os.Build.VERSION.SDK_INT >= 33 && checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) requestPermissions(new String[]{android.Manifest.permission.POST_NOTIFICATIONS}, 53);
                else post();
            });
            Button copy = new Button(this); copy.setText("检查通知复制结果"); page.addView(copy); copy.setOnClickListener(view -> checkCopy());
            Button clear = new Button(this); clear.setText("验证切换分组清除通知"); page.addView(clear); clear.setOnClickListener(view -> checkScope());
            Button shared = new Button(this); shared.setText("只发布共享文本通知"); page.addView(shared); shared.setOnClickListener(view -> postSingle(true));
            Button text = new Button(this); text.setText("只发布接收文本通知"); page.addView(text); text.setOnClickListener(view -> postSingle(false));
            status = new TextView(this); status.setTextSize(17); page.addView(status);
            capture(getIntent()); write();
        } catch (Throwable error) { fail(error); }
    }
    @Override public void onRequestPermissionsResult(int request, String[] permissions, int[] grants) {
        super.onRequestPermissionsResult(request, permissions, grants);
        if (request == 53 && grants.length > 0 && grants[0] == PackageManager.PERMISSION_GRANTED) post();
    }
    private StatusBarNotification notice(String tag) {
        for (StatusBarNotification value : getSystemService(NotificationManager.class).getActiveNotifications()) if (tag.equals(value.getTag())) return value;
        throw new AssertionError("Missing notice " + tag);
    }
    private void post() {
        try {
            result.remove("error");
            notices.clear();
            notices.setScope("ui-test");
            if (!notices.show("ui-test", "pc", "message-1", "1", "Windows 电脑", "第一版中文文本", null, false, "receive")) throw new AssertionError("Notifications unavailable");
            handler.postDelayed(this::edit, 250);
        } catch (Throwable error) { fail(error); }
    }
    private void edit() {
        try {
            Notification first = notice("chat:pc").getNotification(); oldCopy = first.actions[0].actionIntent;
            notices.show("ui-test", "pc", "message-1", "2", "Windows 电脑", "编辑后的中文文本", null, true, "receive");
            handler.postDelayed(this::verifyEdit, 250);
        } catch (Throwable error) { fail(error); }
    }
    private void verifyEdit() {
        try {
            Notification edited = notice("chat:pc").getNotification();
            int pcCount = 0; for (StatusBarNotification value : getSystemService(NotificationManager.class).getActiveNotifications()) if ("chat:pc".equals(value.getTag())) pcCount++;
            if (pcCount != 1 || edited.actions.length != 1) throw new AssertionError("Edit duplicated chat or lost copy");
            android.os.Parcelable[] messages = edited.extras.getParcelableArray(Notification.EXTRA_MESSAGES);
            if (messages == null || messages.length != 1 || !((Bundle) messages[0]).getCharSequence("text").toString().contains("已更新 · 编辑后的中文文本")) throw new AssertionError("Edited message style mismatch");
            result.put("editedSameChat", true); result.put("messagingStyle", edited.extras.getString(Notification.EXTRA_TEMPLATE));
            result.put("channelImportance", getSystemService(NotificationManager.class).getNotificationChannel(ReceiveNotifications.CHANNEL).getImportance());
            oldCopy.send();
            handler.postDelayed(() -> {
                try {
                    String copied = getSystemService(ClipboardManager.class).getPrimaryClip().getItemAt(0).getText().toString();
                    if (!"编辑后的中文文本".equals(copied)) throw new AssertionError("Old copy action did not use latest text");
                    result.put("oldCopyActionUsesLatestText", true); write();
                } catch (Throwable error) { fail(error); }
            }, 180);
            notices.show("ui-test", "file", "file-1", "offered", "手机", null, "截图.png", false, "receive");
            notices.show("ui-test", "clipboard", "clipboard-1", "1", "自动同步", "自动同步的文本", null, false, "receive");
            notices.show("ui-test", "group", "group-document", "1", "组内共享", "组内同步文字", null, false, "shared");
            handler.postDelayed(this::verifyKinds, 250);
        } catch (Throwable error) { fail(error); }
    }
    private void verifyKinds() {
        try {
            Notification file = notice("chat:file").getNotification();
            if (file.actions != null && file.actions.length != 0) throw new AssertionError("File unexpectedly has text-copy action");
            result.put("fileNoCopyAction", true);
            result.put("autoSyncNotice", notice("chat:clipboard").getNotification().actions.length == 1);
            result.put("sharedTextNotice", notice("chat:group").getNotification().actions.length == 1);
            result.put("activeNotifications", getSystemService(NotificationManager.class).getActiveNotifications().length);
            result.put("published", true); write();
        } catch (Throwable error) { fail(error); }
    }
    private void checkCopy() {
        try {
            String copied = getSystemService(ClipboardManager.class).getPrimaryClip().getItemAt(0).getText().toString();
            result.put("lastUiCopiedText", copied); result.put("uiCopyActionPassed", "组内同步文字".equals(copied)); write();
        } catch (Throwable error) { fail(error); }
    }
    private void postSingle(boolean shared) {
        try {
            notices.clear(); notices.setScope("ui-test");
            notices.show("ui-test", shared ? "group" : "pc", "single-message", "1", shared ? "组内共享" : "Windows 电脑", shared ? "组内同步文字" : "点击打开接收文本", null, false, shared ? "shared" : "receive");
        } catch (Throwable error) { fail(error); }
    }
    private void checkScope() {
        try {
            notices.setScope("other-group");
            handler.postDelayed(this::verifyScope, 200);
        } catch (Throwable error) { fail(error); }
    }
    private void verifyScope() {
        try {
            int remaining = getSystemService(NotificationManager.class).getActiveNotifications().length;
            if (remaining != 0) throw new AssertionError("Old group notifications remain");
            result.put("scopeChangeClearsNotices", true); write();
        } catch (Throwable error) { fail(error); }
    }
    private void capture(Intent intent) {
        try {
            String captured = notices.captureOpen(intent), destination = notices.consumeOpen();
            if (!destination.isEmpty()) {
                JSONArray opened = result.optJSONArray("openedTargets"); if (opened == null) opened = new JSONArray();
                opened.put(destination); result.put("openedTargets", opened); result.put("captureMatchesConsume", captured.equals(destination));
            }
        } catch (Throwable error) { fail(error); }
    }
    @Override protected void onNewIntent(Intent intent) { super.onNewIntent(intent); setIntent(intent); capture(intent); write(); }
    private void write() {
        try {
            Files.write(output.toPath(), result.toString(2).getBytes(StandardCharsets.UTF_8));
            if (status != null) status.setText(result.has("error") ? "失败：" + result.optString("error") : result.toString(2));
        } catch (Exception error) { android.util.Log.e("GlobalSendNotifications", "Could not save runtime result", error); }
    }
    private void fail(Throwable error) { try { result.put("error", android.util.Log.getStackTraceString(error)); write(); } catch (Exception ignored) {} android.util.Log.e("GlobalSendNotifications", "Runtime check failed", error); }
    @Override protected void onDestroy() { handler.removeCallbacksAndMessages(null); super.onDestroy(); }
}
