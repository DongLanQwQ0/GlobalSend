package dev.globalsend.globalsend;

import android.content.Context;
import android.os.Build;
import android.provider.Settings;

/** User-visible system name; reading it requires no extra permission. */
final class AndroidDeviceName {
    static String read(Context context) {
        String value = Settings.Global.getString(context.getContentResolver(), "device_name");
        return value == null || value.trim().isEmpty() ? Build.MODEL.trim() : value.trim();
    }
}
