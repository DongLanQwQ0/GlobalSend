package dev.globalsend.globalsend;

import android.Manifest;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Build;
import org.json.JSONArray;
import org.json.JSONObject;

/** Compact OS overlay first; item-specific notices only when presentation fails. */
public final class ReceiveNotifications {
    public static final String CHANNEL = "received-messages";
    public static final String OPEN = "dev.globalsend.OPEN_RECEIVED";
    public static final String COPY = "dev.globalsend.COPY_RECEIVED";
    public static final String FULL_SCREEN = "dev.globalsend.FULL_SCREEN_RECEIPT";
    public static final String PRESENTATION_ID = "dev.globalsend.RECEIPT_PRESENTATION_ID";
    private static final int NOTICE_ID = 7820;
    private static final String PREFS = "received-notifications";
    private final Context context;
    private final SharedPreferences preferences;
    private final NotificationManager manager;
    private final SharedPreferences popupPreferences;
    private boolean foreground;
    private boolean popupRejected;
    interface Presenter {
        void show(Receipt receipt, long generation, java.util.function.Consumer<Boolean> shown);
        void hide();
    }
    static final class Receipt {
        final String id, version, source, text, fileName, localPath;
        final long size;
        Receipt(String id, String version, String source, String text, String fileName, String localPath, long size) {
            this.id = id; this.version = version; this.source = source; this.text = text;
            this.fileName = fileName == null ? "" : fileName;
            this.localPath = localPath == null ? "" : localPath; this.size = size;
        }
    }
    private final Presenter presenter;
    private java.util.function.BiConsumer<java.util.Map<String, String>, Long> dismissListener;
    private static final class PopupAttempt {
        final String tag;
        final int noticeId;
        boolean succeeded;
        PopupAttempt(String tag, int noticeId) { this.tag = tag; this.noticeId = noticeId; }
    }
    private final java.util.Map<String, PopupAttempt> popupAttempts = new java.util.HashMap<>();
    private long arrivalGeneration;
    private java.util.function.LongConsumer arrivalListener;

    public ReceiveNotifications(Context context) { this(context, null); }
    ReceiveNotifications(Context context, Presenter presenter) {
        this.context = context.getApplicationContext();
        preferences = this.context.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        popupPreferences = this.context.getSharedPreferences("received-popup-settings", Context.MODE_PRIVATE);
        manager = this.context.getSystemService(NotificationManager.class);
        this.presenter = presenter == null ? new ReceiveOverlay(this.context, new ReceiveOverlay.Actions() {
            public void open(String id) { openReceipt(id); }
            public void copy(String id) {
                try { ReceiveNotifications.this.copy(new Intent(COPY).setData(actionUri("copy", "chat:item:" + id))
                    .putExtra("notificationTag", "chat:item:" + id)); }
                catch (Exception ignored) { }
            }
            public void dismiss(java.util.Map<String, String> versions, long generation) {
                if (dismissListener != null) dismissListener.accept(versions, generation);
            }
        }) : presenter;
        if (Build.VERSION.SDK_INT >= 26) {
            NotificationChannel channel = new NotificationChannel(CHANNEL, "收到的内容", NotificationManager.IMPORTANCE_HIGH);
            channel.setDescription("收到文件、文字与消息更新");
            manager.createNotificationChannel(channel);
        }
        clearSharedNotifications();
    }

    /** Remove only the shared-editor notices emitted by older releases. */
    private void clearSharedNotifications() {
        SharedPreferences.Editor edit = preferences.edit().remove("version:group-shared-text");
        manager.cancel("chat:group-shared-text", NOTICE_ID);
        for (String key : preferences.getAll().keySet()) {
            if (!key.startsWith("chat:")) continue;
            try {
                JSONObject record = new JSONObject(preferences.getString(key, "{}"));
                if ("shared".equals(record.optString("target"))) {
                    manager.cancel(key, NOTICE_ID);
                    edit.remove(key);
                }
            } catch (org.json.JSONException ignored) { }
        }
        if ("shared".equals(preferences.getString("pendingOpen", ""))) edit.remove("pendingOpen");
        edit.apply();
    }

    public boolean enabled() {
        if (Build.VERSION.SDK_INT >= 33 && context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return false;
        if (!manager.areNotificationsEnabled()) return false;
        return Build.VERSION.SDK_INT < 26 || manager.getNotificationChannel(CHANNEL).getImportance() != NotificationManager.IMPORTANCE_NONE;
    }

    public boolean popupEnabled() { return popupPreferences.getBoolean("enabled", true); }
    public boolean headsUpAllowed() {
        return enabled() && (Build.VERSION.SDK_INT < 26 ||
            manager.getNotificationChannel(CHANNEL).getImportance() >= NotificationManager.IMPORTANCE_HIGH);
    }

    public void setPopupEnabled(boolean enabled) {
        popupPreferences.edit().putBoolean("enabled", enabled).apply();
    }

    public boolean popupAllowed() {
        return Build.VERSION.SDK_INT < 23 || android.provider.Settings.canDrawOverlays(context);
    }

    public boolean freeformSupported() {
        return Build.VERSION.SDK_INT >= 24 && context.getPackageManager()
            .hasSystemFeature(PackageManager.FEATURE_FREEFORM_WINDOW_MANAGEMENT);
    }

    public synchronized void setForeground(boolean value) {
        foreground = value;
        if (value) {
            presenter.hide();
            for (PopupAttempt attempt : popupAttempts.values()) attempt.succeeded = true;
        }
        if (value && !popupRejected) cancelDisplayedNotices();
    }

    synchronized void setPopupRejected(boolean value) {
        popupRejected = value;
        if (!value && foreground) cancelDisplayedNotices();
    }

    synchronized void presentationResult(String id, boolean converted, boolean resumed) {
        PopupAttempt attempt = popupAttempts.get(id);
        if (attempt == null || attempt.succeeded) return;
        if (converted && resumed) {
            // Latch this request's real presentation, not the current foreground snapshot.
            attempt.succeeded = true;
            manager.cancel(attempt.tag, attempt.noticeId);
        } else if (!converted) {
            popupRejected = true;
        }
    }

    synchronized long arrivalGeneration() { return arrivalGeneration; }
    void setArrivalListener(java.util.function.LongConsumer listener) { arrivalListener = listener; }
    void setDismissListener(java.util.function.BiConsumer<java.util.Map<String, String>, Long> listener) { dismissListener = listener; }
    synchronized boolean dismissIfCurrent(Long expected, java.util.function.BooleanSupplier close) {
        if (expected != null && expected != arrivalGeneration) return true;
        return close.getAsBoolean();
    }

    private void cancelDisplayedNotices() {
        for (String key : preferences.getAll().keySet()) if (key.startsWith("chat:")) {
            manager.cancel(key, NOTICE_ID);
            try { manager.cancel(key, new JSONObject(preferences.getString(key, "{}")).optInt("noticeId", NOTICE_ID)); }
            catch (org.json.JSONException ignored) { }
        }
    }

    public synchronized void setScope(String scope) {
        if (scope.equals(preferences.getString("scope", ""))) return;
        clear();
        preferences.edit().putString("scope", scope).apply();
    }

    public synchronized void clear() {
        popupAttempts.clear();
        presenter.hide();
        cancelDisplayedNotices();
        preferences.edit().clear().apply();
    }

    /** Version is a server cursor/revision, or a file's offered/received phase. */
    public synchronized boolean show(String scope, String conversation, String itemId, String version,
            String sourceName, String text, String fileName, boolean updated, String target) throws Exception {
        return show(scope, conversation, itemId, version, sourceName, text, fileName, updated, target, null, 0);
    }
    public synchronized boolean show(String scope, String conversation, String itemId, String version,
            String sourceName, String text, String fileName, boolean updated, String target, String localPath, long size) throws Exception {
        if ("shared".equals(target)) return false;
        if (!scope.equals(preferences.getString("scope", "")) || scope.isEmpty()) return false;
        String versionKey = "version:" + itemId;
        if (version.equals(preferences.getString(versionKey, ""))) return false;
        // Each item owns its actions; every real version gets fresh attention,
        // even while an earlier notice is still present in the notification shade.
        String tag = "chat:item:" + itemId;
        JSONObject record = new JSONObject(preferences.getString(tag, "{}"));
        int previousId = record.optInt("noticeId", NOTICE_ID);
        int noticeId = preferences.getInt("nextNoticeId", NOTICE_ID) + 1;
        JSONArray messages = record.optJSONArray("messages");
        if (messages == null) messages = new JSONArray();
        JSONArray next = new JSONArray();
        for (int i = Math.max(0, messages.length() - 7); i < messages.length(); i++) {
            JSONObject message = messages.getJSONObject(i);
            if (!itemId.equals(message.getString("id"))) next.put(message);
        }
        String body = text != null ? (text.isEmpty() ? "空文本" : text) : fileName;
        String preview = body.length() > 1500 ? body.substring(0, 1500) + "…" : body;
        long now = System.currentTimeMillis();
        next.put(new JSONObject().put("id", itemId).put("body", (updated ? "已更新 · " : "") + preview).put("time", now));
        record.put("messages", next).put("source", sourceName).put("target", target)
            .put("itemId", itemId).put("noticeId", noticeId);
        if (text != null) record.put("copyText", text); else record.remove("copyText");
        preferences.edit().putString(versionKey, version).putString(tag, record.toString())
            .putInt("nextNoticeId", noticeId).apply();
        arrivalGeneration++;
        if (arrivalListener != null) arrivalListener.accept(arrivalGeneration);
        Notification.Builder builder = Build.VERSION.SDK_INT >= 26 ? new Notification.Builder(context, CHANNEL) : new Notification.Builder(context);
        Notification.MessagingStyle style = new Notification.MessagingStyle("我").setConversationTitle(sourceName);
        for (int i = 0; i < next.length(); i++) {
            JSONObject message = next.getJSONObject(i);
            style.addMessage(message.getString("body"), message.getLong("time"), sourceName);
        }
        Intent open = context.getPackageManager().getLaunchIntentForPackage(context.getPackageName());
        if (open == null) throw new IllegalStateException("Application launch activity is unavailable");
        open.setAction(OPEN).setData(actionUri("open", tag)).putExtra("notificationTag", tag)
            .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP | Intent.FLAG_ACTIVITY_SINGLE_TOP);
        PendingIntent openAction = PendingIntent.getActivity(context, 0, open, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        builder.setSmallIcon(android.R.drawable.stat_notify_chat).setContentTitle(sourceName).setContentText(preview)
            .setCategory(Notification.CATEGORY_MESSAGE).setStyle(style).setWhen(now).setShowWhen(true)
            .setAutoCancel(true).setPriority(Notification.PRIORITY_HIGH).setContentIntent(openAction);
        if (text != null) {
            Intent copy = new Intent(context, ReceiveNotificationCopyReceiver.class).setAction(COPY)
                .setData(actionUri("copy", tag)).putExtra("notificationTag", tag);
            PendingIntent action = PendingIntent.getBroadcast(context, 0, copy, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
            builder.addAction(new Notification.Action.Builder(android.R.drawable.ic_menu_set_as, "复制", action).build());
        }
        manager.cancel(tag, previousId);
        if (foreground) return true; // The receive page is already presenting this batch.
        Notification fallback = builder.build();
        if (popupEnabled() && popupAllowed()) {
            String presentationId = java.util.UUID.randomUUID().toString();
            PopupAttempt attempt = new PopupAttempt(tag, noticeId);
            popupAttempts.put(presentationId, attempt);
            try {
                popupRejected = false;
                presenter.show(new Receipt(itemId, version, sourceName, text, fileName, localPath, size),
                    arrivalGeneration, attached -> {
                        synchronized (ReceiveNotifications.this) {
                            if (popupAttempts.get(presentationId) != attempt) return;
                            presentationResult(presentationId, attached, attached);
                        }
                    });
                // Suppress a fallback only after the native view is attached and
                // has reached a content-bearing pre-draw, not merely addView().
                new android.os.Handler(android.os.Looper.getMainLooper()).postDelayed(() -> {
                    synchronized (ReceiveNotifications.this) {
                        if (popupAttempts.remove(presentationId) != attempt) return;
                        try {
                            JSONObject latest = new JSONObject(preferences.getString(tag, "{}"));
                            if (!attempt.succeeded && latest.optInt("noticeId") == noticeId && enabled())
                                manager.notify(tag, noticeId, fallback);
                        } catch (org.json.JSONException ignored) { }
                    }
                }, 1000);
                return true;
            } catch (RuntimeException denied) { popupAttempts.remove(presentationId); /* Fallback below. */ }
        }
        if (!enabled()) return false;
        manager.notify(tag, noticeId, fallback);
        return true;
    }

    private Uri actionUri(String action, String tag) {
        return new Uri.Builder().scheme("globalsend-notification").authority(action).appendPath(context.getPackageName())
            .appendQueryParameter("tag", tag).appendQueryParameter("scope", preferences.getString("scope", "")).build();
    }

    private void openReceipt(String itemId) {
        Intent open = context.getPackageManager().getLaunchIntentForPackage(context.getPackageName());
        if (open == null) return;
        String tag = "chat:item:" + itemId;
        open.setAction(OPEN).setData(actionUri("open", tag)).putExtra("notificationTag", tag)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TOP | Intent.FLAG_ACTIVITY_SINGLE_TOP);
        context.startActivity(open);
        presenter.hide();
    }

    public synchronized boolean copy(Intent intent) throws Exception {
        if (!COPY.equals(intent.getAction()) || intent.getData() == null ||
                !preferences.getString("scope", "").equals(intent.getData().getQueryParameter("scope"))) return false;
        String tag = intent.getStringExtra("notificationTag");
        String value = tag == null ? null : preferences.getString(tag, null);
        if (value == null) return false;
        JSONObject record = new JSONObject(value);
        if (!record.has("copyText")) return false;
        context.getSystemService(ClipboardManager.class).setPrimaryClip(ClipData.newPlainText("GlobalSend", record.getString("copyText")));
        return true;
    }

    public synchronized String captureOpen(Intent intent) {
        if (!OPEN.equals(intent.getAction()) || intent.getData() == null ||
                !preferences.getString("scope", "").equals(intent.getData().getQueryParameter("scope"))) return "";
        String tag = intent.getStringExtra("notificationTag");
        try {
            if (tag == null || !preferences.contains(tag)) return "";
            JSONObject record = new JSONObject(preferences.getString(tag, "{}"));
            String target = record.optString("target", "receive");
            if ("shared".equals(target)) return "";
            String itemId = record.optString("itemId");
            if (!itemId.isEmpty()) target = "receive:" + itemId;
            preferences.edit().putString("pendingOpen", target).apply();
            return target;
        } catch (Exception ignored) { return ""; }
    }

    public String consumeOpen() {
        String target = preferences.getString("pendingOpen", "");
        preferences.edit().remove("pendingOpen").apply();
        return target;
    }
}
