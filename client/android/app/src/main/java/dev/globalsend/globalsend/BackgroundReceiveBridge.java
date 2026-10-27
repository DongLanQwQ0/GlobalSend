package dev.globalsend.globalsend;

import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.os.PowerManager;
import android.provider.Settings;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodChannel;
import java.lang.ref.WeakReference;
import java.util.HashMap;
import java.util.Map;

/** One engine-owned session; no Activity or live file is retained by the UI host. */
final class BackgroundReceiveBridge {
    private final NativeReceiveRuntime runtime;
    private final Context context;
    private final MethodChannel channel;
    private WeakReference<Activity> attached = new WeakReference<>(null);
    private boolean visible, connected, transferring;
    private String error = "";
    BackgroundReceiveBridge(NativeReceiveRuntime runtime, BinaryMessenger messenger) {
        this.runtime = runtime; context = runtime.context;
        channel = new MethodChannel(messenger, "dev.globalsend/background-receive");
        channel.setMethodCallHandler((call, result) -> {
            try {
                switch (call.method) {
                    case "status": result.success(status()); break;
                    case "session":
                        boolean authenticated = Boolean.TRUE.equals(call.argument("authenticated"));
                        BackgroundReceiveService.preferences(context).edit().putBoolean("authenticated", authenticated).commit();
                        connected = Boolean.TRUE.equals(call.argument("connected")); transferring = Boolean.TRUE.equals(call.argument("transferring"));
                        reconcile(); result.success(status()); break;
                    case "enabled":
                        BackgroundReceiveService.preferences(context).edit().putBoolean("enabled", Boolean.TRUE.equals(call.argument("enabled"))).commit();
                        reconcile(); result.success(status()); break;
                    case "batterySettings":
                        Activity host = attached.get();
                        if (host == null || !visible) throw new IllegalStateException("请在应用中打开后台设置");
                        PowerManager power = (PowerManager) context.getSystemService(Context.POWER_SERVICE);
                        if (!power.isIgnoringBatteryOptimizations(context.getPackageName()))
                            host.startActivity(new Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, android.net.Uri.parse("package:" + context.getPackageName())));
                        else host.startActivity(new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, android.net.Uri.parse("package:" + context.getPackageName())));
                        result.success(null); break;
                    default: result.notImplemented();
                }
            } catch (Exception failure) { error = failure.getMessage(); result.error("BACKGROUND_RECEIVE", error, null); emit(); }
        });
    }
    void attach(Activity activity) { attached = new WeakReference<>(activity); }
    void detach(Activity activity) { if (attached.get() == activity) { attached.clear(); visible = false; } }
    void visible(Activity activity, boolean value) {
        if (attached.get() != activity) return;
        visible = value;
        if (value) { error = ""; reconcile(); }
        emit();
    }
    private void reconcile() {
        if (!BackgroundReceiveService.wanted(context)) {
            context.stopService(new Intent(context, BackgroundReceiveService.class)); emit(); return;
        }
        if (BackgroundReceiveService.current == null) {
            if (!visible) { error = "回到应用后开启后台接收"; emit(); return; }
            BackgroundReceiveService.start(context);
        } else BackgroundReceiveService.current.update(connected, transferring);
        emit();
    }
    Map<String,Object> status() {
        Map<String,Object> value = new HashMap<>();
        boolean enabled = BackgroundReceiveService.preferences(context).getBoolean("enabled", true);
        boolean running = BackgroundReceiveService.current != null;
        value.put("enabled", enabled); value.put("running", running);
        value.put("batteryUnrestricted", ((PowerManager) context.getSystemService(Context.POWER_SERVICE)).isIgnoringBatteryOptimizations(context.getPackageName()));
        value.put("status", !enabled ? "已暂停" : running ? connected ? transferring ? "后台传输中" : "后台接收中" : "重新连接中" : error.isEmpty() ? "连接后自动开启" : error);
        value.put("engineId", System.identityHashCode(runtime.engine)); value.put("engineCreatedAt", runtime.createdAt);
        return value;
    }
    private void emit() { channel.invokeMethod("state", status()); }
    void serviceChanged() {
        if (BackgroundReceiveService.current != null) BackgroundReceiveService.current.update(connected, transferring);
        emit();
    }
    void pauseRequested() { channel.invokeMethod("pause", null); emit(); }
}
