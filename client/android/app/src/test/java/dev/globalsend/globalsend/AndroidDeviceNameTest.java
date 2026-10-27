package dev.globalsend.globalsend;

import static org.junit.Assert.*;
import android.content.Context;
import android.os.Build;
import android.provider.Settings;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;
import org.robolectric.annotation.Config;

@RunWith(RobolectricTestRunner.class)
@Config(sdk = 28, manifest = Config.NONE)
public class AndroidDeviceNameTest {
    @Test public void prefersSystemDeviceNameAndFallsBackToModelWithoutRequestingPermissions() {
        Context context = RuntimeEnvironment.getApplication();
        Settings.Global.putString(context.getContentResolver(), "device_name", "  DongLan 的 vivo  ");
        assertEquals("DongLan 的 vivo", AndroidDeviceName.read(context));
        Settings.Global.putString(context.getContentResolver(), "device_name", " ");
        assertEquals(Build.MODEL.trim(), AndroidDeviceName.read(context));
        Settings.Global.putString(context.getContentResolver(), "device_name", null);
        assertEquals(Build.MODEL.trim(), AndroidDeviceName.read(context));
    }
}
