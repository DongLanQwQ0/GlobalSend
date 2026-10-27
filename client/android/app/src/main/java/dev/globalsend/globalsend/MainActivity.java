package dev.globalsend.globalsend;

import android.content.Context;
import android.content.Intent;
import android.os.Bundle;
import androidx.annotation.NonNull;
import io.flutter.embedding.android.FlutterActivity;
import io.flutter.embedding.engine.FlutterEngine;

/** Normal UI host; native receiver overlays never resize or convert this Activity. */
public class MainActivity extends FlutterActivity {
    private NativeReceiveRuntime runtime;
    @Override public FlutterEngine provideFlutterEngine(@NonNull Context context) {
        runtime = NativeReceiveRuntime.ensure(context);
        return runtime.engine;
    }
    @Override public boolean shouldDestroyEngineWithHost() { return false; }
    @Override public void configureFlutterEngine(@NonNull FlutterEngine engine) {
        super.configureFlutterEngine(engine);
        if (runtime == null) runtime = NativeReceiveRuntime.ensure(this);
        runtime.attach(this);
    }
    @Override protected void onCreate(Bundle state) {
        super.onCreate(state);
        runtime.intent(getIntent());
    }
    @Override public void onNewIntent(Intent intent) {
        super.onNewIntent(intent); setIntent(intent);
        runtime.intent(intent);
    }
    // Compatibility for existing Dart callers. OEM freeform chrome belongs to
    // the system alone; the receiver no longer draws an Activity-sized frame.
    boolean isReceiptFloating() { return false; }
    boolean beginReceivedWindowGesture(long downTime, boolean resize) { return false; }
    boolean endReceivedWindowGesture(long downTime) { return false; }
    boolean adjustReceivedWindow(float dx, float dy, float dw, float dh) { return false; }
    boolean expandReceivedWindow() { return true; }
    boolean dismissReceivedWindow() { return true; }
    @Override protected void onResume() {
        super.onResume();
        runtime.background.visible(this, true);
        runtime.visible(this, true);
        runtime.resumed();
        runtime.presentationChanged(false);
    }
    @Override protected void onPause() {
        runtime.background.visible(this, false);
        runtime.visible(this, false);
        super.onPause();
    }
    @Override protected void onActivityResult(int requestCode,int resultCode,Intent data) {
        if (runtime != null && runtime.activityResult(requestCode,resultCode,data)) return;
        super.onActivityResult(requestCode,resultCode,data);
    }
    @Override public void onRequestPermissionsResult(int requestCode,@NonNull String[] permissions,@NonNull int[] results) {
        super.onRequestPermissionsResult(requestCode,permissions,results);
        if (runtime != null && requestCode == ReceiveNotificationBridge.PERMISSION_REQUEST) runtime.permissionChanged();
    }
    @Override protected void onDestroy() {
        if (runtime != null) runtime.detach(this);
        super.onDestroy();
    }
}
