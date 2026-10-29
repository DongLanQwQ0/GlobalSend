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
    @Test public void edgeHandleChangesTheActualWindowAndKeepsShelfSeparateOnForeground() throws Exception {
        ReceiveOverlay overlay = receiver(); show(overlay, "remote", 1);
        org.robolectric.Shadows.shadowOf(android.os.Looper.getMainLooper()).idle();
        View root = (View)field(overlay, "root"); draw(root);
        TemporaryShelf shelf = (TemporaryShelf)field(overlay, "shelf");
        shelf.add(java.util.List.of(), java.util.List.of("仅暂存"), Map.of());
        overlay.foreground();
        org.robolectric.Shadows.shadowOf(android.os.Looper.getMainLooper()).idleFor(java.time.Duration.ofMillis(280));
        WindowManager.LayoutParams size = (WindowManager.LayoutParams)root.getLayoutParams();
        float dp = root.getResources().getDisplayMetrics().density;
        assertEquals(Math.round(18*dp), size.width); assertEquals(Math.round(72*dp), size.height);
        assertEquals(0, root.getPaddingLeft()); assertEquals(0, root.getPaddingRight());
        assertTrue(root.isAttachedToWindow()); assertEquals(1,shelf.items.size());
        assertEquals(View.GONE,((View)field(overlay,"expanded")).getVisibility());
        ((View)field(overlay,"handle")).performClick();
        org.robolectric.Shadows.shadowOf(android.os.Looper.getMainLooper()).idleFor(java.time.Duration.ofMillis(280));
        assertEquals(Math.round(232*dp), size.width);
        assertEquals(Math.round(4*dp), ((View)field(overlay,"expanded")).getPaddingLeft());
        assertEquals(Math.round(1*dp), ((View)field(overlay,"expanded")).getPaddingRight());
        ((View)field(overlay,"shelfTab")).performClick();
        LinearLayout row=(LinearLayout)field(overlay,"row"); assertEquals(2,row.getChildCount());
        assertEquals("仅暂存",((android.widget.TextView)((android.widget.FrameLayout)row.getChildAt(0)).getChildAt(0)).getText().toString());
        ((View)field(overlay,"count")).performClick();
        assertEquals("remote",((android.widget.TextView)((android.widget.FrameLayout)row.getChildAt(0)).getChildAt(0)).getText().toString());
        overlay.hide();
    }

    @Test public void oneTapOnAnyChildCancelsRemovalWithoutOpeningOrDeletingIt() throws Exception {
        ReceiveOverlay overlay=receiver(); show(overlay,"remote",1);
        org.robolectric.Shadows.shadowOf(android.os.Looper.getMainLooper()).idle();
        TemporaryShelf shelf=(TemporaryShelf)field(overlay,"shelf");
        shelf.add(java.util.List.of(),java.util.List.of("保留我"),Map.of());
        ((View)field(overlay,"shelfTab")).performClick();
        View root=(View)field(overlay,"root"); draw(root);
        View card=((LinearLayout)field(overlay,"row")).getChildAt(0);
        shelf.exported(new java.util.ArrayList<>(shelf.items.values()),true);
        root.dispatchTouchEvent(android.view.MotionEvent.obtain(0,0,android.view.MotionEvent.ACTION_DOWN,30,65,0));
        root.dispatchTouchEvent(android.view.MotionEvent.obtain(0,10,android.view.MotionEvent.ACTION_UP,30,65,0));
        org.robolectric.Shadows.shadowOf(android.os.Looper.getMainLooper()).idleFor(java.time.Duration.ofSeconds(4));
        assertEquals(1,shelf.items.size()); assertEquals(0,shelf.removalSeconds()); assertSame(root,field(overlay,"root"));
        overlay.hide();
    }
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
        assertTrue(layout.width <= Math.round(244*dp));
        assertTrue(layout.height <= Math.round(156*dp));
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
        assertEquals(3,row.getChildCount());
        assertEquals(LinearLayout.HORIZONTAL,row.getOrientation());
        assertEquals(row.getChildAt(0).getLayoutParams().width,row.getChildAt(0).getLayoutParams().height);
        overlay.show(new ReceiveNotifications.Receipt("one","2","电脑","修改第一条",null,null,0),3,acks::add);
        assertEquals(3,row.getChildCount());
        overlay.hide();
        assertNull(field(overlay,"root"));
        assertNotEquals(0,((WindowManager.LayoutParams)root.getLayoutParams()).flags & WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE);
        org.robolectric.Shadows.shadowOf(android.os.Looper.getMainLooper()).idleFor(java.time.Duration.ofMillis(200));
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
        root.setAlpha(1); root.setTranslationX(0); root.setScaleX(1); root.setScaleY(1);
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
        org.robolectric.Shadows.shadowOf(android.os.Looper.getMainLooper()).idleFor(java.time.Duration.ofMillis(200));
    }

    private ReceiveOverlay receiver() {
        return new ReceiveOverlay(RuntimeEnvironment.getApplication(),new ReceiveOverlay.Actions() {
            public void open(String id) { }
            public void copy(String id) { }
            public void dismiss(Map<String,String> versions,long generation) { }
        });
    }
    private void show(ReceiveOverlay overlay,String id,long generation) {
        overlay.show(new ReceiveNotifications.Receipt(id,"1","电脑",id,null,null,0),generation,shown -> { });
    }
    private void draw(View root) {
        WindowManager.LayoutParams layout = (WindowManager.LayoutParams)root.getLayoutParams();
        root.measure(View.MeasureSpec.makeMeasureSpec(layout.width,View.MeasureSpec.EXACTLY),
            View.MeasureSpec.makeMeasureSpec(layout.height,View.MeasureSpec.EXACTLY));
        root.layout(0,0,layout.width,layout.height);
        root.getViewTreeObserver().dispatchOnPreDraw();
    }

    @Test public void oldExitCannotRemoveNewWindowAndLateFirstFrameCannotResurrectOldWindow() throws Exception {
        ReceiveOverlay overlay = receiver();
        show(overlay,"old",1);
        org.robolectric.Shadows.shadowOf(android.os.Looper.getMainLooper()).idle();
        View old = (View)field(overlay,"root");
        // Hide during the first-frame/enter interval, then immediately receive again.
        overlay.hide();
        old.animate().cancel(); // Cancellation must not cancel ownership cleanup.
        show(overlay,"new",2);
        org.robolectric.Shadows.shadowOf(android.os.Looper.getMainLooper()).idle();
        View current = (View)field(overlay,"root");
        assertNotSame(old,current);
        draw(old); draw(current);
        org.robolectric.Shadows.shadowOf(android.os.Looper.getMainLooper()).idleFor(java.time.Duration.ofMillis(250));
        assertFalse(old.isAttachedToWindow());
        assertSame(current,field(overlay,"root"));
        assertTrue(current.isAttachedToWindow());
        assertEquals(1f,current.getAlpha(),.001f);
        overlay.hide();
        org.robolectric.Shadows.shadowOf(android.os.Looper.getMainLooper()).idleFor(java.time.Duration.ofMillis(200));
    }

    @Test public void sameItemUpdateKeepsScrollAndDoesNotReplayEntrance() throws Exception {
        ReceiveOverlay overlay = receiver();
        show(overlay,"one",1); show(overlay,"two",2); show(overlay,"three",3);
        org.robolectric.Shadows.shadowOf(android.os.Looper.getMainLooper()).idle();
        View root = (View)field(overlay,"root");
        draw(root);
        org.robolectric.Shadows.shadowOf(android.os.Looper.getMainLooper()).idleFor(java.time.Duration.ofMillis(250));
        android.widget.HorizontalScrollView scroll = (android.widget.HorizontalScrollView)field(overlay,"scroll");
        scroll.scrollTo(50,0);
        int before = scroll.getScrollX();
        assertTrue(before > 0);
        overlay.show(new ReceiveNotifications.Receipt("one","2","电脑","编辑正文",null,null,0),4,shown -> { });
        assertSame(root,field(overlay,"root"));
        draw(root);
        org.robolectric.Shadows.shadowOf(android.os.Looper.getMainLooper()).idle();
        assertEquals(before,scroll.getScrollX());
        assertEquals(1f,root.getAlpha(),.001f);
        assertEquals(0f,root.getTranslationX(),.001f);
        assertEquals(4,((LinearLayout)field(overlay,"row")).getChildCount());
        overlay.hide();
        org.robolectric.Shadows.shadowOf(android.os.Looper.getMainLooper()).idleFor(java.time.Duration.ofMillis(200));
    }

    @Test public void hideBeforeAttachDoesNotLeaveAnUnownedWindow() throws Exception {
        ReceiveOverlay overlay = receiver();
        show(overlay,"one",1);
        View old = (View)field(overlay,"root");
        overlay.hide();
        org.robolectric.Shadows.shadowOf(android.os.Looper.getMainLooper()).idleFor(java.time.Duration.ofSeconds(1));
        assertNull(field(overlay,"root"));
        assertFalse(old.isAttachedToWindow());
    }

    @Test public void arrivalAfterADeferredCloseIsPresentedAfterNativeDragEnds() throws Exception {
        ReceiveOverlay overlay = receiver();
        show(overlay,"old",1);
        org.robolectric.Shadows.shadowOf(android.os.Looper.getMainLooper()).idle();
        View old = (View)field(overlay,"root");
        View card = ((LinearLayout)field(overlay,"row")).getChildAt(0);
        Class<?> sessionClass = Class.forName("dev.globalsend.globalsend.DockCoordinator$LocalDrag");
        java.lang.reflect.Constructor<?> constructor = sessionClass.getDeclaredConstructor(View.class,String.class,String.class);
        constructor.setAccessible(true);
        Object session = constructor.newInstance(card,null,"old");
        java.lang.reflect.Field active = DockCoordinator.class.getDeclaredField("activeExport");
        active.setAccessible(true); active.set(null,session);
        try {
            overlay.hide(); // Must leave the drag's source view attached until system drag finishes.
            java.util.List<Boolean> received = new java.util.ArrayList<>();
            overlay.show(new ReceiveNotifications.Receipt("new","1","手机","新消息",null,null,0),2,received::add);
            assertSame(old,field(overlay,"root"));
            assertTrue(old.isAttachedToWindow());
            assertTrue(received.isEmpty());
            java.lang.reflect.Method finish = DockCoordinator.class.getDeclaredMethod("finishExport",sessionClass);
            finish.setAccessible(true); finish.invoke(null,session);
            org.robolectric.Shadows.shadowOf(android.os.Looper.getMainLooper()).idle();
            View current = (View)field(overlay,"root");
            assertNotSame(old,current);
            draw(current);
            assertEquals(java.util.List.of(true),received);
            assertEquals(2,((LinearLayout)field(overlay,"row")).getChildCount());
            org.robolectric.Shadows.shadowOf(android.os.Looper.getMainLooper()).idleFor(java.time.Duration.ofMillis(250));
            assertFalse(old.isAttachedToWindow());
            assertTrue(current.isAttachedToWindow());
        } finally {
            active.set(null,null); overlay.hide();
            org.robolectric.Shadows.shadowOf(android.os.Looper.getMainLooper()).idleFor(java.time.Duration.ofMillis(200));
        }
    }
}
