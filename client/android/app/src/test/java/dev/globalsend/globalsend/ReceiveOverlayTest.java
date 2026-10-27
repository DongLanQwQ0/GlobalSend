package dev.globalsend.globalsend;

import static org.junit.Assert.*;
import android.content.Context;
import android.view.View;
import android.view.WindowManager;
import android.widget.LinearLayout;
import java.util.Map;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;
import org.robolectric.annotation.Config;

@RunWith(RobolectricTestRunner.class)
@Config(sdk=34, manifest=Config.NONE)
public class ReceiveOverlayTest {
    private Object field(Object value, String name) throws Exception {
        java.lang.reflect.Field field = value.getClass().getDeclaredField(name);
        field.setAccessible(true); return field.get(value);
    }
    @Test public void actualWindowIsBoundedNonModalAndBatchUpdatesReuseOneSurface() throws Exception {
        Context context = RuntimeEnvironment.getApplication();
        ReceiveOverlay overlay = new ReceiveOverlay(context, new ReceiveOverlay.Actions() {
            public void open(String id) { }
            public void copy(String id) { }
            public void dismiss(Map<String,String> versions, long generation) { }
        });
        java.util.List<Boolean> acks = new java.util.ArrayList<>();
        overlay.show(new ReceiveNotifications.Receipt("one","1","电脑","第一条",null,null,0), 1, acks::add);
        View root = (View) field(overlay,"root");
        assertNotNull(root);
        WindowManager.LayoutParams layout = (WindowManager.LayoutParams) root.getLayoutParams();
        assertEquals(WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY, layout.type);
        assertNotEquals(0, layout.flags & WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE);
        assertNotEquals(0, layout.flags & WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL);
        assertEquals(0, layout.flags & WindowManager.LayoutParams.FLAG_DIM_BEHIND);
        float dp = context.getResources().getDisplayMetrics().density;
        assertTrue(layout.width <= Math.round(272*dp));
        assertTrue(layout.height <= Math.round(184*dp));
        assertTrue(acks.isEmpty()); // addView alone is not presentation acknowledgement.
        org.robolectric.Shadows.shadowOf(android.os.Looper.getMainLooper()).idle();
        assertTrue(root.isAttachedToWindow());
        root.measure(View.MeasureSpec.makeMeasureSpec(layout.width,View.MeasureSpec.EXACTLY),
            View.MeasureSpec.makeMeasureSpec(layout.height,View.MeasureSpec.EXACTLY));
        root.layout(0,0,layout.width,layout.height);
        root.getViewTreeObserver().dispatchOnPreDraw();
        assertEquals(java.util.List.of(true),acks);
        overlay.show(new ReceiveNotifications.Receipt("two","1","手机","第二条",null,null,0), 2, acks::add);
        assertSame(root, field(overlay,"root"));
        LinearLayout row = (LinearLayout) field(overlay,"row");
        assertEquals(2,row.getChildCount());
        assertEquals(LinearLayout.HORIZONTAL,row.getOrientation());
        assertEquals(row.getChildAt(0).getLayoutParams().width,row.getChildAt(0).getLayoutParams().height);
        overlay.show(new ReceiveNotifications.Receipt("one","2","电脑","修改第一条",null,null,0),3,acks::add);
        assertEquals(2,row.getChildCount());
        overlay.hide();
        assertNull(field(overlay,"root"));
        assertFalse(root.isAttachedToWindow());
    }
    @Test public void closeCarriesOnlyDisplayedVersionsAndDoesNotStartAnActivity() throws Exception {
        Context context = RuntimeEnvironment.getApplication();
        java.util.List<Map<String,String>> closed = new java.util.ArrayList<>();
        java.util.List<Long> generations = new java.util.ArrayList<>();
        ReceiveOverlay overlay = new ReceiveOverlay(context,new ReceiveOverlay.Actions() {
            public void open(String id) { fail("Close must not open the application"); }
            public void copy(String id) { }
            public void dismiss(Map<String,String> versions,long generation) { closed.add(versions); generations.add(generation); }
        });
        overlay.show(new ReceiveNotifications.Receipt("one","received","电脑","正文",null,null,0),7,shown -> { });
        java.lang.reflect.Method dismiss = ReceiveOverlay.class.getDeclaredMethod("dismiss");
        dismiss.setAccessible(true); dismiss.invoke(overlay);
        assertEquals(java.util.List.of(Map.of("one","received")),closed);
        assertEquals(java.util.List.of(7L),generations);
        assertNull(field(overlay,"root"));
    }

    @Test @org.robolectric.annotation.GraphicsMode(org.robolectric.annotation.GraphicsMode.Mode.NATIVE)
    @Config(qualifiers="w393dp-h851dp-xxhdpi")
    public void compactLayoutRendersCardsWithoutAFullScreenBackdrop() throws Exception {
        Context context = RuntimeEnvironment.getApplication();
        ReceiveOverlay overlay = new ReceiveOverlay(context,new ReceiveOverlay.Actions() {
            public void open(String id) { }
            public void copy(String id) { }
            public void dismiss(Map<String,String> versions,long generation) { }
        });
        overlay.show(new ReceiveNotifications.Receipt("one","1","DongLan","请周六上午九点集合。\n新收到的内容可以拖出。",null,null,0),1,shown -> { });
        overlay.show(new ReceiveNotifications.Receipt("two","1","我的手机","收到。\n稍后发送设计稿。",null,null,0),2,shown -> { });
        org.robolectric.Shadows.shadowOf(android.os.Looper.getMainLooper()).idle();
        View root = (View) field(overlay,"root");
        WindowManager.LayoutParams size = (WindowManager.LayoutParams) root.getLayoutParams();
        root.measure(View.MeasureSpec.makeMeasureSpec(size.width,View.MeasureSpec.EXACTLY),
            View.MeasureSpec.makeMeasureSpec(size.height,View.MeasureSpec.EXACTLY));
        root.layout(0,0,size.width,size.height);
        root.setAlpha(1); root.setTranslationX(0);
        android.graphics.Bitmap image = android.graphics.Bitmap.createBitmap(size.width,size.height,android.graphics.Bitmap.Config.ARGB_8888);
        root.draw(new android.graphics.Canvas(image));
        assertTrue(size.height < context.getResources().getDisplayMetrics().heightPixels / 2);
        assertNotEquals(0,image.getPixel(size.width/2,size.height/2));
        String output = System.getenv("GLOBALSEND_TEST_ARTIFACTS");
        if (output != null) {
            java.io.File file = new java.io.File(output,"android-overlay-compact.png");
            file.getParentFile().mkdirs();
            try (java.io.FileOutputStream stream = new java.io.FileOutputStream(file)) {
                image.compress(android.graphics.Bitmap.CompressFormat.PNG,100,stream);
            }
        }
        overlay.hide();
    }
}
