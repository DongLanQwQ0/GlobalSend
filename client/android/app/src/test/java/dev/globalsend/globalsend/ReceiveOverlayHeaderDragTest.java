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
        assertEquals(3, header.getChildCount());
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
        android.widget.TextView received=(android.widget.TextView)header.getChildAt(0);
        assertEquals("1",received.getText().toString());
        assertEquals("0",((android.widget.TextView)shelf).getText().toString());
        assertNotNull(received.getCompoundDrawablesRelative()[2]);
        assertNotNull(((android.widget.TextView)shelf).getCompoundDrawablesRelative()[2]);
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
        int expandedWidth = window.width, expandedHeight = window.height, expandedX = window.x;
        float density=root.getResources().getDisplayMetrics().density;
        capture(overlay,"expanded-before");
        overlay.setCollapsed(true);
        advanceGeometry(overlay,80);
        assertTrue("intermediate width="+window.width,window.width < expandedWidth && window.width > Math.round(18*density));
        assertTrue("window moves right while shrinking",window.x > expandedX);
        draw(root);
        assertEquals("content moves with the window, not pinned to screen edge",0,panel.getLeft());
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
        assertEquals(Math.round(18*density),window.width); assertEquals(Math.round(72*density),window.height);
        assertEquals(View.GONE,panel.getVisibility()); assertEquals(View.VISIBLE,handle.getVisibility());
        capture(overlay,"collapsed");
        handle.performClick();
        advanceGeometry(overlay,80);
        assertTrue(window.width > Math.round(18*density) && window.width < expandedWidth);
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
    @Test public void topRightRemoveAndTailClearOperateOnOnlyCurrentList() throws Exception {
        ReceiveOverlay overlay=create(new int[3]);
        TemporaryShelf shelf=(TemporaryShelf)field(overlay,"shelf");
        shelf.add(java.util.List.of(),java.util.List.of("one","two"),Map.of());
        ((View)field(overlay,"shelfTab")).performClick();
        LinearLayout row=(LinearLayout)field(overlay,"row");
        assertEquals(3,row.getChildCount());
        LinearLayout card=(LinearLayout)row.getChildAt(0);
        android.widget.FrameLayout preview=(android.widget.FrameLayout)card.getChildAt(0);
        assertEquals("移除",preview.getChildAt(1).getContentDescription());
        preview.getChildAt(1).performClick();
        assertEquals(1,shelf.items.size());
        assertEquals("清空当前列表",row.getChildAt(row.getChildCount()-1).getContentDescription());
        row.getChildAt(row.getChildCount()-1).performClick();
        assertTrue(shelf.items.isEmpty());
        assertEquals(1,((Map<?,?>)field(overlay,"items")).size());
        overlay.hide();
    }
    @Test @Config(shadows=AndroidDragTest.NativeDragView.class)
    public void acceptedDropStillExpiresWhenDockWasHiddenBeforeNativeCompletion() throws Exception {
        AndroidDragTest.NativeDragView.resetFixture();
        ReceiveOverlay overlay=create(new int[3]);
        TemporaryShelf shelf=(TemporaryShelf)field(overlay,"shelf");
        shelf.add(java.util.List.of(),java.util.List.of("expire"),Map.of());
        ((View)field(overlay,"shelfTab")).performClick();
        View source=new View(RuntimeEnvironment.getApplication());
        ((android.widget.FrameLayout)field(overlay,"root")).addView(source);
        java.lang.reflect.Method export=ReceiveOverlay.class.getDeclaredMethod("export",View.class,java.util.List.class);
        export.setAccessible(true);
        assertTrue((Boolean)export.invoke(overlay,source,new java.util.ArrayList<>(shelf.items.values())));
        DockCoordinator.LocalDrag session=(DockCoordinator.LocalDrag)AndroidDragTest.NativeDragView.states.get(0);
        overlay.hide(); // queued until native drag ends, before completion callback
        session.accepted=true;
        java.lang.reflect.Method finish=DockCoordinator.class.getDeclaredMethod("finishExport",DockCoordinator.LocalDrag.class);
        finish.setAccessible(true); finish.invoke(null,session);
        assertNull(field(overlay,"root"));
        assertEquals(3,shelf.removalSeconds());
        Shadows.shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(2999));
        assertEquals(1,shelf.items.size());
        Shadows.shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(1));
        assertTrue(shelf.items.isEmpty());
    }
    @Test @org.robolectric.annotation.GraphicsMode(org.robolectric.annotation.GraphicsMode.Mode.NATIVE)
    public void pendingCardsAreRedAndTouchCanContinueIntoLongPressWhileCancelingWholeBatch() throws Exception {
        ReceiveOverlay overlay=create(new int[3]);
        TemporaryShelf shelf=(TemporaryShelf)field(overlay,"shelf");
        shelf.add(java.util.List.of(),java.util.List.of("one","two"),Map.of());
        ((View)field(overlay,"shelfTab")).performClick();
        shelf.exported(new java.util.ArrayList<>(shelf.items.values()),true);
        View root=(View)field(overlay,"root"); draw(root);
        View card=((LinearLayout)field(overlay,"row")).getChildAt(0);
        int[] held={0};
        card.setOnLongClickListener(view -> { held[0]++; return true; });
        assertEquals(View.VISIBLE,card.findViewWithTag("pending-removal").getVisibility());
        assertEquals(0xffffe4e6,((android.graphics.drawable.GradientDrawable)card.getBackground()).getColor().getDefaultColor());
        capture(overlay,"pending-red");
        touch(root,0,MotionEvent.ACTION_DOWN,25,60);
        assertEquals(0,shelf.removalSeconds());
        assertSame("cancel must not rebuild away the touched drag source",card,((LinearLayout)field(overlay,"row")).getChildAt(0));
        assertEquals(View.GONE,card.findViewWithTag("pending-removal").getVisibility());
        capture(overlay,"pending-canceled");
        Shadows.shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(ViewConfiguration.getLongPressTimeout()+100));
        assertEquals("long press still reaches the card's drag handler",1,held[0]);
        touch(root,1000,MotionEvent.ACTION_CANCEL,25,60);
        Shadows.shadowOf(Looper.getMainLooper()).idleFor(Duration.ofSeconds(4));
        assertEquals(2,shelf.items.size());
        overlay.hide();
    }
    private void advanceGeometry(ReceiveOverlay overlay,long millis) throws Exception {
        android.animation.ValueAnimator animator=(android.animation.ValueAnimator)field(overlay,"geometry");
        assertNotNull("transition is active",animator);
        animator.setCurrentPlayTime(millis);
        if(millis>=animator.getDuration())animator.end();
    }
    @Test public void contentDoubleTapOpensApplicationWithoutAlsoOpeningTheItem() throws Exception {
        android.content.Context context=RuntimeEnvironment.getApplication();
        android.content.pm.ResolveInfo launcher=new android.content.pm.ResolveInfo();
        launcher.activityInfo=new android.content.pm.ActivityInfo();
        launcher.activityInfo.packageName=context.getPackageName();launcher.activityInfo.name="test.GlobalSendActivity";
        launcher.activityInfo.applicationInfo=new android.content.pm.ApplicationInfo();
        launcher.activityInfo.applicationInfo.packageName=context.getPackageName();
        Shadows.shadowOf(context.getPackageManager()).addResolveInfoForIntent(
            new android.content.Intent(android.content.Intent.ACTION_MAIN).addCategory(android.content.Intent.CATEGORY_LAUNCHER).setPackage(context.getPackageName()),launcher);
        int[] actions=new int[3];ReceiveOverlay overlay=create(actions);
        View root=(View)field(overlay,"root");
        touch(root,0,MotionEvent.ACTION_DOWN,25,60);touch(root,10,MotionEvent.ACTION_UP,25,60);
        Shadows.shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(50));
        touch(root,0,MotionEvent.ACTION_DOWN,25,60);touch(root,10,MotionEvent.ACTION_UP,25,60);
        Shadows.shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(400));
        android.content.Intent opened=Shadows.shadowOf(RuntimeEnvironment.getApplication()).getNextStartedActivity();
        assertNotNull(opened);assertEquals("test.GlobalSendActivity",opened.getComponent().getClassName());
        assertArrayEquals(new int[3],actions);
        overlay.hide();
    }
    @Test @org.robolectric.annotation.GraphicsMode(org.robolectric.annotation.GraphicsMode.Mode.NATIVE)
    public void collapsedVisualStaysThinButInvisibleHitAreaIsOneAndHalfTimesAsLarge() throws Exception {
        ReceiveOverlay overlay=create(new int[3]);
        org.robolectric.shadows.ShadowChoreographer.setPaused(true);
        overlay.setCollapsed(true);advanceGeometry(overlay,240);
        View root=(View)field(overlay,"root"), handle=(View)field(overlay,"handle");draw(root);
        float density=root.getResources().getDisplayMetrics().density;
        WindowManager.LayoutParams window=(WindowManager.LayoutParams)root.getLayoutParams();
        assertEquals(Math.round(12*density*1.5f),window.width);
        assertEquals(Math.round(48*density*1.5f),window.height);
        assertEquals(0,((android.graphics.drawable.GradientDrawable)root.getBackground()).getColor().getDefaultColor());
        android.graphics.Bitmap pixels=android.graphics.Bitmap.createBitmap(window.width,window.height,android.graphics.Bitmap.Config.ARGB_8888);
        root.draw(new android.graphics.Canvas(pixels));
        assertEquals("expanded hit margin stays invisible",0,android.graphics.Color.alpha(pixels.getPixel(1,Math.round(36*density))));
        assertTrue("grip is visible above its translucent backing",android.graphics.Color.alpha(pixels.getPixel(Math.round(12*density),Math.round(36*density)))>100);
        pixels.recycle();
        capture(overlay,"expanded-hit-area");
        touch(handle,0,MotionEvent.ACTION_DOWN,1,30*density);
        touch(handle,10,MotionEvent.ACTION_UP,1,30*density);
        assertFalse((Boolean)field(overlay,"collapsed"));
        advanceGeometry(overlay,240);overlay.hide();
    }
    @Test public void settingClosesWindowAndPreservesStagedContent() throws Exception {
        ReceiveOverlay overlay=create(new int[3]);
        TemporaryShelf shelf=(TemporaryShelf)field(overlay,"shelf");
        shelf.add(java.util.List.of(),java.util.List.of("keep"),Map.of());
        ReceiveOverlay.closeShelf();
        assertNull(field(overlay,"root"));assertEquals(1,shelf.items.size());
        assertFalse(RuntimeEnvironment.getApplication().getSharedPreferences("received-popup-settings",0).getBoolean("enabled",true));
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

    private void reflow(ReceiveOverlay overlay,android.graphics.Rect bounds) throws Exception {
        java.lang.reflect.Method method=ReceiveOverlay.class.getDeclaredMethod("reflowForBounds",android.graphics.Rect.class);
        method.setAccessible(true);method.invoke(overlay,bounds);
    }
    private void setField(Object owner,String name,Object value) throws Exception {
        java.lang.reflect.Field f=owner.getClass().getDeclaredField(name);f.setAccessible(true);f.set(owner,value);
    }
    private void assertInside(WindowManager.LayoutParams window,android.graphics.Rect bounds) {
        assertTrue(bounds.contains(window.x,window.y,window.x+window.width,window.y+window.height));
    }
    @Test public void rotationKeepsExpandedDockAtSameEdgesAndRetainsContent() throws Exception {
        ReceiveOverlay overlay=create(new int[3]);View root=(View)field(overlay,"root");
        android.graphics.Rect portrait=new android.graphics.Rect((android.graphics.Rect)field(overlay,"lastBounds"));
        WindowManager.LayoutParams window=(WindowManager.LayoutParams)root.getLayoutParams();
        int x=window.x,y=window.y,rightGap=portrait.right-window.x-window.width,bottomGap=portrait.bottom-window.y-window.height;
        android.graphics.Rect landscape=new android.graphics.Rect(0,24,1200,776);
        reflow(overlay,landscape);
        assertSame(root,field(overlay,"root"));assertInside(window,landscape);
        assertEquals(rightGap,landscape.right-window.x-window.width);
        assertEquals(bottomGap,landscape.bottom-window.y-window.height);
        assertEquals(1,((Map<?,?>)field(overlay,"items")).size());
        reflow(overlay,portrait);assertEquals(x,window.x);assertEquals(y,window.y);
        // Exercise the production configuration callback with real framework metrics.
        RuntimeEnvironment.setQualifiers("w1200dp-h800dp-land");
        ((android.content.ComponentCallbacks)field(overlay,"configurationChanges")).onConfigurationChanged(RuntimeEnvironment.getApplication().getResources().getConfiguration());
        Shadows.shadowOf(Looper.getMainLooper()).idle();
        assertInside(window,(android.graphics.Rect)field(overlay,"lastBounds"));
        assertTrue(((android.graphics.Rect)field(overlay,"lastBounds")).width()>((android.graphics.Rect)field(overlay,"lastBounds")).height());
        overlay.hide();
    }
    @Test public void rotationKeepsCollapsedHandleOnItsChosenEdge() throws Exception {
        ReceiveOverlay overlay=create(new int[3]);
        org.robolectric.shadows.ShadowChoreographer.setPaused(true);
        WindowManager.LayoutParams window=(WindowManager.LayoutParams)((View)field(overlay,"root")).getLayoutParams();
        android.graphics.Rect portrait=new android.graphics.Rect((android.graphics.Rect)field(overlay,"lastBounds"));
        for(boolean right:new boolean[]{true,false}) {
            window.x=right?portrait.right-window.width:portrait.left;window.y=portrait.centerY();
            overlay.setCollapsed(true);advanceGeometry(overlay,240);
            android.graphics.Rect landscape=new android.graphics.Rect(0,24,1200,776);
            reflow(overlay,landscape);
            assertTrue((Boolean)field(overlay,"collapsed"));assertEquals(right,(Boolean)field(overlay,"edgeRight"));
            assertInside(window,landscape);assertEquals(right?landscape.right-window.width:landscape.left,window.x);
            reflow(overlay,portrait);
            overlay.setCollapsed(false);advanceGeometry(overlay,240);
        }
        overlay.hide();
    }
    @Test public void rotationFinishesOldAnimationAndRestoresUserSizeAfterShortDisplay() throws Exception {
        ReceiveOverlay overlay=create(new int[3]);
        org.robolectric.shadows.ShadowChoreographer.setPaused(true);
        WindowManager.LayoutParams window=(WindowManager.LayoutParams)((View)field(overlay,"root")).getLayoutParams();
        android.graphics.Rect portrait=new android.graphics.Rect((android.graphics.Rect)field(overlay,"lastBounds"));
        setField(overlay,"preferredWidth",360);setField(overlay,"preferredHeight",260);
        setField(overlay,"expandedWidth",360);setField(overlay,"expandedHeight",260);
        window.width=360;window.height=260;
        overlay.setCollapsed(true);advanceGeometry(overlay,80);
        android.graphics.Rect shortDisplay=new android.graphics.Rect(0,0,1200,240);
        reflow(overlay,shortDisplay);assertNull(field(overlay,"geometry"));assertInside(window,shortDisplay);
        int x=window.x,y=window.y;
        Shadows.shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(400));
        assertEquals(x,window.x);assertEquals(y,window.y);
        overlay.setCollapsed(false);advanceGeometry(overlay,240);
        assertEquals(224,window.height);assertEquals(360,window.width);
        reflow(overlay,portrait);assertEquals(260,window.height);assertEquals(360,window.width);
        assertInside(window,portrait);overlay.hide();
    }
}
