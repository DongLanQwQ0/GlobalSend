package dev.globalsend.globalsend;

import static org.junit.Assert.*;
import android.os.Looper;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewConfiguration;
import android.view.WindowManager;
import android.widget.LinearLayout;
import java.time.Duration;
import java.util.Map;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;
import org.robolectric.Shadows;
import org.robolectric.annotation.Config;

@RunWith(RobolectricTestRunner.class)
@Config(sdk=34, manifest=Config.NONE, qualifiers="w800dp-h1200dp")
public class ReceiveOverlayHeaderDragTest {
    private long gestureStart;
    private Object field(Object owner, String name) throws Exception {
        java.lang.reflect.Field f = owner.getClass().getDeclaredField(name);
        f.setAccessible(true); return f.get(owner);
    }
    private ReceiveOverlay create(int[] actions) throws Exception {
        ReceiveOverlay overlay = new ReceiveOverlay(RuntimeEnvironment.getApplication(), new ReceiveOverlay.Actions() {
            public void open(String id) { actions[0]++; }
            public void copy(String id) { actions[1]++; }
            public void dismiss(Map<String,String> versions, long generation) { actions[2]++; }
        });
        overlay.show(new ReceiveNotifications.Receipt("fixture", "1", "test", "synthetic", null, null, 0), 1, ignored -> {});
        Shadows.shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(250));
        draw((View)field(overlay, "root"));
        ((View)field(overlay,"root")).getViewTreeObserver().dispatchOnPreDraw();
        Shadows.shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(250));
        return overlay;
    }
    private void draw(View root) {
        WindowManager.LayoutParams p = (WindowManager.LayoutParams)root.getLayoutParams();
        root.measure(View.MeasureSpec.makeMeasureSpec(p.width, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(p.height, View.MeasureSpec.EXACTLY));
        root.layout(0, 0, p.width, p.height);
    }
    private boolean touch(View view, long when, int action, float x, float y) {
        if (action == MotionEvent.ACTION_DOWN) gestureStart = android.os.SystemClock.uptimeMillis();
        MotionEvent event = MotionEvent.obtain(gestureStart, gestureStart + when, action, x, y, 0);
        try { return view.dispatchTouchEvent(event); } finally { event.recycle(); }
    }
    @Test public void draggingFromEveryTitleRowControlMovesWithoutClickingOrJumping() throws Exception {
        int[] actions = new int[3];
        ReceiveOverlay overlay = create(actions);
        View root = (View)field(overlay, "root");
        LinearLayout header = (LinearLayout)field(overlay, "header");
        WindowManager.LayoutParams window = (WindowManager.LayoutParams)root.getLayoutParams();
        assertEquals(6, header.getChildCount());
        assertTrue("header width", header.getWidth() > 0);
        assertTrue("header height", header.getHeight() > 0);
        for (int i=0; i<header.getChildCount(); i++) {
            View control = header.getChildAt(i);
            float x = (control.getLeft() + control.getRight()) / 2f, y = header.getHeight() / 2f;
            int beforeX = window.x, beforeY = window.y;
            assertTrue("DOWN " + header.getClass().getName() + " at " + x + "," + y, touch(header, 0, MotionEvent.ACTION_DOWN, x, y));
            assertTrue("tracking after DOWN", (Boolean)field(header, "tracking"));
            touch(header, 30, MotionEvent.ACTION_MOVE, x - 30, y - 30);
            touch(header, 60, MotionEvent.ACTION_UP, x - 30, y - 30);
            assertEquals("horizontal offset for child " + i, beforeX - 30, window.x);
            assertEquals("vertical offset for child " + i, beforeY - 30, window.y);
            assertSame(root, field(overlay, "root"));
            assertFalse((Boolean)field(overlay, "collapsed"));
            assertFalse((Boolean)field(overlay, "shelfVisible"));
        }
        assertArrayEquals(new int[3], actions);
        overlay.hide();
    }
    @Test public void titleRowStillDeliversTapAndStationaryBulkLongPress() throws Exception {
        ReceiveOverlay overlay = create(new int[3]);
        LinearLayout header = (LinearLayout)field(overlay, "header");
        View shelf = header.getChildAt(1), bulk = header.getChildAt(2);
        float x = (shelf.getLeft()+shelf.getRight())/2f, y=header.getHeight()/2f;
        touch(header, 0, MotionEvent.ACTION_DOWN, x, y);
        touch(header, 10, MotionEvent.ACTION_UP, x, y);
        Shadows.shadowOf(Looper.getMainLooper()).idle();
        assertTrue((Boolean)field(overlay,"shelfVisible"));
        int[] held = {0};
        bulk.setOnLongClickListener(view -> { held[0]++; return true; });
        x=(bulk.getLeft()+bulk.getRight())/2f;
        touch(header, 0, MotionEvent.ACTION_DOWN, x, y);
        Shadows.shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(ViewConfiguration.getLongPressTimeout()+100));
        assertEquals(1,held[0]);
        touch(header, 1000, MotionEvent.ACTION_CANCEL, x, y);
        assertFalse((Boolean)field(overlay,"collapsed"));
        overlay.hide();
    }

    @Test @org.robolectric.annotation.GraphicsMode(org.robolectric.annotation.GraphicsMode.Mode.NATIVE)
    @org.robolectric.annotation.LooperMode(org.robolectric.annotation.LooperMode.Mode.PAUSED)
    public void snapAndExpandInterpolateBoundsAndFadeFixedSizeContentWithoutOldCompletionWinning() throws Exception {
        ReceiveOverlay overlay = create(new int[3]);
        View root = (View)field(overlay,"root"), panel = (View)field(overlay,"expanded"), handle = (View)field(overlay,"handle");
        // Control vsync explicitly: the default shadow auto-advances the clock
        // for every posted frame and otherwise runs the whole animation at once.
        org.robolectric.shadows.ShadowChoreographer.setPaused(true);
        org.robolectric.shadows.ShadowChoreographer.setFrameDelay(Duration.ofMillis(16));
        WindowManager.LayoutParams window = (WindowManager.LayoutParams)root.getLayoutParams();
        int expandedWidth = window.width, expandedHeight = window.height;
        float density=root.getResources().getDisplayMetrics().density;
        capture(overlay,"expanded-before");
        overlay.setCollapsed(true);
        advanceGeometry(overlay,80);
        assertTrue("intermediate width="+window.width,window.width < expandedWidth && window.width > Math.round(12*density));
        assertTrue(panel.getAlpha() < 1);
        assertEquals(expandedWidth,panel.getLayoutParams().width);
        capture(overlay,"snap-intermediate");
        // Reverse an in-flight snap. Canceling the old animator must not hide
        // the expanded panel when that old animation would have completed.
        overlay.setCollapsed(false);
        advanceGeometry(overlay,240);
        assertEquals(expandedWidth,window.width); assertEquals(expandedHeight,window.height);
        assertEquals(View.VISIBLE,panel.getVisibility()); assertEquals(1f,panel.getAlpha(),.001f);
        assertEquals(View.GONE,handle.getVisibility());
        overlay.setCollapsed(true);
        advanceGeometry(overlay,240);
        assertEquals(Math.round(12*density),window.width); assertEquals(Math.round(48*density),window.height);
        assertEquals(View.GONE,panel.getVisibility()); assertEquals(View.VISIBLE,handle.getVisibility());
        capture(overlay,"collapsed");
        handle.performClick();
        advanceGeometry(overlay,80);
        assertTrue(window.width > Math.round(12*density) && window.width < expandedWidth);
        assertTrue(handle.getAlpha() < 1);
        assertEquals(expandedWidth,panel.getLayoutParams().width);
        capture(overlay,"expand-intermediate");
        overlay.setCollapsed(true);
        advanceGeometry(overlay,240);
        handle.performClick();
        advanceGeometry(overlay,240);
        assertEquals(expandedWidth,window.width); assertEquals(View.VISIBLE,panel.getVisibility());
        capture(overlay,"expanded-after");
        overlay.hide();
    }
    private void advanceGeometry(ReceiveOverlay overlay,long millis) throws Exception {
        android.animation.ValueAnimator animator=(android.animation.ValueAnimator)field(overlay,"geometry");
        assertNotNull("transition is active",animator);
        animator.setCurrentPlayTime(millis);
        if(millis>=animator.getDuration())animator.end();
    }
    private void capture(ReceiveOverlay overlay,String name) throws Exception {
        String directory=System.getenv("GLOBALSEND_TEST_ARTIFACTS");
        if(directory==null)return;
        View root=(View)field(overlay,"root");
        WindowManager.LayoutParams window=(WindowManager.LayoutParams)root.getLayoutParams();
        draw(root);
        android.graphics.Bitmap bitmap=android.graphics.Bitmap.createBitmap(window.width,window.height,android.graphics.Bitmap.Config.ARGB_8888);
        root.draw(new android.graphics.Canvas(bitmap));
        java.io.File folder=new java.io.File(directory);folder.mkdirs();
        try(java.io.FileOutputStream out=new java.io.FileOutputStream(new java.io.File(folder,name+".png"))){bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG,100,out);}
        bitmap.recycle();
        String metadata="{\"x\":"+window.x+",\"y\":"+window.y+",\"width\":"+window.width+",\"height\":"+window.height+"}";
        java.nio.file.Files.write(new java.io.File(folder,name+".json").toPath(),metadata.getBytes(java.nio.charset.StandardCharsets.UTF_8));
    }
}
