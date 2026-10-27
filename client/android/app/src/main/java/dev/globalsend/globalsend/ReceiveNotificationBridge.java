package dev.globalsend.globalsend;

import android.Manifest;
import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.os.Build;
import android.provider.Settings;
import io.flutter.plugin.common.MethodChannel;

final class ReceiveNotificationBridge {
    static final int PERMISSION_REQUEST = 7841;
    private final Context context;
    private java.lang.ref.WeakReference<Activity> attached = new java.lang.ref.WeakReference<>(null);
    private boolean resumed;
    private final MethodChannel channel;
    private final ReceiveNotifications notifications;
    ReceiveNotificationBridge(Context context, io.flutter.plugin.common.BinaryMessenger messenger) {
        this.context = context.getApplicationContext();
        notifications = new ReceiveNotifications(this.context);
        MethodChannel windowChannel = new MethodChannel(messenger, "dev.globalsend/system");
        notifications.setArrivalListener(generation -> {
            java.util.Map<String, Object> state = new java.util.HashMap<>();
            state.put("arrivalGeneration", generation);
            windowChannel.invokeMethod("receiptArrival", state);
        });
        if (context instanceof Activity) attach((Activity) context);
        channel = new MethodChannel(messenger, "dev.globalsend/received-notifications");
        notifications.setDismissListener((versions, generation) -> {
            java.util.Map<String, Object> value = new java.util.HashMap<>();
            value.put("versions", versions);
            value.put("arrivalGeneration", generation);
            channel.invokeMethod("dismiss", value);
        });
        channel.setMethodCallHandler((call, result) -> {
            try {
                switch (call.method) {
                    case "status": result.success(notifications.enabled()); break;
                    case "popupState": result.success(popupState()); break;
                    case "notificationSettings":
                        Activity notificationHost = attached.get();
                        if (notificationHost == null || !notificationHost.hasWindowFocus())
                            throw new IllegalStateException("请回到应用后设置");
                        notificationHost.startActivity(Build.VERSION.SDK_INT >= 26
                            ? new Intent(Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS)
                                .putExtra(Settings.EXTRA_APP_PACKAGE, context.getPackageName())
                                .putExtra(Settings.EXTRA_CHANNEL_ID, ReceiveNotifications.CHANNEL)
                            : new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                android.net.Uri.parse("package:" + context.getPackageName())));
                        result.success(null); break;
                    case "popupEnabled":
                        notifications.setPopupEnabled(Boolean.TRUE.equals(call.argument("enabled")));
                        result.success(popupState()); break;
                    case "foreground":
                        Activity foregroundHost = attached.get();
                        notifications.setForeground(Boolean.TRUE.equals(call.argument("foreground")) &&
                            resumed && foregroundHost != null && foregroundHost.hasWindowFocus());
                        result.success(null); break;
                    case "popupSettings":
                        Activity popupHost = attached.get();
                        if (popupHost == null || popupHost.isFinishing() || !popupHost.hasWindowFocus()) {
                            throw new IllegalStateException("请回到应用后设置");
                        }
                        if (Build.VERSION.SDK_INT >= 23) {
                            popupHost.startActivity(new Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                                android.net.Uri.parse("package:" + popupHost.getPackageName())));
                        } else {
                            popupHost.startActivity(Build.VERSION.SDK_INT >= 26
                                ? new Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, popupHost.getPackageName())
                                : new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, android.net.Uri.parse("package:" + popupHost.getPackageName())));
                        }
                        result.success(null); break;
                    case "scope": notifications.setScope(call.argument("scope")); result.success(null); break;
                    case "clear": notifications.clear(); result.success(null); break;
                    case "pendingOpen": result.success(notifications.consumeOpen()); break;
                    case "permission":
                        Activity activity = attached.get();
                        if (activity == null || activity.isFinishing() || !activity.hasWindowFocus()) {
                            result.success(notifications.enabled()); break;
                        }
                        boolean explicit = Boolean.TRUE.equals(call.argument("explicit"));
                        android.content.SharedPreferences preferences = activity.getSharedPreferences("notification-permission", 0);
                        boolean asked = preferences.getBoolean("asked", false);
                        boolean missingPermission = Build.VERSION.SDK_INT >= 33 && activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED;
                        if (missingPermission && activity.hasWindowFocus() &&
                                (!asked || explicit && activity.shouldShowRequestPermissionRationale(Manifest.permission.POST_NOTIFICATIONS))) {
                            preferences.edit().putBoolean("asked", true).apply();
                            activity.requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, PERMISSION_REQUEST);
                        } else if (explicit && !notifications.enabled()) {
                            activity.startActivity(Build.VERSION.SDK_INT >= 26
                                ? new Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, activity.getPackageName())
                                : new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, android.net.Uri.parse("package:" + activity.getPackageName())));
                        }
                        result.success(notifications.enabled()); break;
                    case "show":
                        Number size = call.argument("size");
                        result.success(notifications.show(call.argument("scope"), call.argument("conversation"), call.argument("itemId"),
                            call.argument("version"), call.argument("sourceName"), call.argument("text"), call.argument("fileName"),
                            Boolean.TRUE.equals(call.argument("updated")), call.argument("target"), call.argument("localPath"),
                            size == null ? 0 : size.longValue()));
                        break;
                    default: result.notImplemented();
                }
            } catch (Exception error) { result.error("NOTIFICATION_FAILED", error.getMessage(), null); }
        });
    }
    void attach(Activity activity) {
        attached = new java.lang.ref.WeakReference<>(activity);
        resumed = false;
        notifications.setForeground(false);
    }
    void visible(Activity activity, boolean foreground) {
        if (attached.get() == activity) {
            resumed = foreground;
            notifications.setForeground(foreground);
        }
    }
    void detach(Activity activity) {
        if (attached.get() == activity) { attached.clear(); resumed = false; notifications.setForeground(false); }
    }
    void opened(Intent intent) {
        String target = notifications.captureOpen(intent);
        Activity activity = attached.get();
        if (activity != null && Build.VERSION.SDK_INT >= 27) {
            boolean popup = !target.isEmpty() && intent.getBooleanExtra(ReceiveNotifications.FULL_SCREEN, false);
            boolean stillFloating = activity instanceof MainActivity && ((MainActivity) activity).isReceiptFloating();
            if (popup || !stillFloating) {
                activity.setShowWhenLocked(popup);
                activity.setTurnScreenOn(popup);
            }
        }
        if (!target.isEmpty()) channel.invokeMethod("open", target);
    }
    void presentationRejected(boolean rejected) { notifications.setPopupRejected(rejected); }
    void presentationResult(String id, boolean converted, boolean resumed) {
        notifications.presentationResult(id, converted, resumed);
    }
    long arrivalGeneration() { return notifications.arrivalGeneration(); }
    boolean dismissIfCurrent(Long expected, java.util.function.BooleanSupplier close) {
        return notifications.dismissIfCurrent(expected, close);
    }
    java.util.Map<String, Object> popupState() {
        java.util.Map<String, Object> state = new java.util.HashMap<>();
        state.put("enabled", notifications.popupEnabled());
        state.put("allowed", notifications.popupAllowed());
        state.put("headsUpAllowed", notifications.headsUpAllowed());
        state.put("freeformSupported", notifications.freeformSupported());
        return state;
    }
    void permissionChanged() {
        channel.invokeMethod("permission", notifications.enabled());
        channel.invokeMethod("popupState", popupState());
    }
    void dispose() { channel.setMethodCallHandler(null); }
}
