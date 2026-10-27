package dev.globalsend.globalsend;
import static org.junit.Assert.*;
import android.app.Activity;
import android.view.WindowManager;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.Robolectric;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.annotation.Config;

@RunWith(RobolectricTestRunner.class)
@Config(sdk=34, manifest=Config.NONE)
public class ReceiveWindowPresentationTest {
    @Test public void retiredAdapterNeverChangesActivityBoundsOrTranslucency() {
        Activity activity = Robolectric.buildActivity(Activity.class).setup().get();
        WindowManager.LayoutParams before = new WindowManager.LayoutParams();
        before.copyFrom(activity.getWindow().getAttributes());
        android.graphics.drawable.Drawable background = activity.getWindow().getDecorView().getBackground();
        ReceiveWindowPresentation presentation = new ReceiveWindowPresentation(activity, (host, value) -> {
            fail("Must not convert the main Activity to translucent"); return false;
        });
        assertEquals(ReceiveWindowPresentation.Result.UNSUPPORTED, presentation.show());
        assertFalse(presentation.isFloating());
        assertFalse(presentation.adjust(100,100,100,100));
        assertTrue(presentation.restore());
        WindowManager.LayoutParams after = activity.getWindow().getAttributes();
        assertEquals(before.width,after.width); assertEquals(before.height,after.height);
        assertEquals(before.x,after.x); assertEquals(before.y,after.y);
        assertEquals(before.flags,after.flags);
        assertSame(background,activity.getWindow().getDecorView().getBackground());
    }
}
