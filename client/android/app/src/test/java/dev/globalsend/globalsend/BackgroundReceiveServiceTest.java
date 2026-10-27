package dev.globalsend.globalsend;

import static org.junit.Assert.*;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.Robolectric;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;
import org.robolectric.annotation.Config;

@RunWith(RobolectricTestRunner.class)
@Config(sdk = 28)
public final class BackgroundReceiveServiceTest {
    private Context context;
    @Before public void setup() {
        context = RuntimeEnvironment.getApplication();
        BackgroundReceiveService.preferences(context).edit().clear().commit();
    }
    @Test public void aNewInstallDoesNotStartBeforeThereIsAnAuthenticatedSession() {
        assertFalse(BackgroundReceiveService.wanted(context));
        BackgroundReceiveService.preferences(context).edit().putBoolean("authenticated", true).commit();
        assertTrue(BackgroundReceiveService.wanted(context));
        BackgroundReceiveService.preferences(context).edit().putBoolean("enabled", false).commit();
        assertFalse(BackgroundReceiveService.wanted(context));
    }
    @Test public void notificationPauseIsPersistedBeforeTheRuntimeCanReconnect() {
        BackgroundReceiveService.preferences(context).edit().putBoolean("authenticated", true).commit();
        var controller = Robolectric.buildService(BackgroundReceiveService.class).create();
        BackgroundReceiveService service = controller.get();
        assertEquals(Service.START_NOT_STICKY, service.onStartCommand(
            new Intent(context, BackgroundReceiveService.class).setAction(BackgroundReceiveService.PAUSE), 0, 1));
        assertFalse(BackgroundReceiveService.wanted(context));
        assertFalse(BackgroundReceiveService.preferences(context).getBoolean("enabled", true));
        controller.destroy();
    }
    @Test public void aLoggedOutStickyRestartStopsWithoutCreatingAnEngine() {
        var controller = Robolectric.buildService(BackgroundReceiveService.class).create();
        assertEquals(Service.START_NOT_STICKY, controller.get().onStartCommand(null, 0, 1));
        assertNull(BackgroundReceiveService.current);
        controller.destroy();
    }
}
