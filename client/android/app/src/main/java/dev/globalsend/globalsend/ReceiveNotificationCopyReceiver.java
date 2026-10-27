package dev.globalsend.globalsend;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.widget.Toast;

public final class ReceiveNotificationCopyReceiver extends BroadcastReceiver {
    @Override public void onReceive(Context context, Intent intent) {
        try {
            if (new ReceiveNotifications(context).copy(intent) && android.os.Build.VERSION.SDK_INT < 33)
                Toast.makeText(context, "已复制", Toast.LENGTH_SHORT).show();
        } catch (Exception ignored) { Toast.makeText(context, "内容已不可用", Toast.LENGTH_SHORT).show(); }
    }
}
