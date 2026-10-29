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
        // Deliver the OS frame coordinates: the shadow's updateViewLayout
        // updates sizes but otherwise retains its original attach-info origin.
        Object attached=org.robolectric.util.ReflectionHelpers.getField(root,"mAttachInfo");
        org.robolectric.util.ReflectionHelpers.setField(attached,"mWindowLeft",p.x);
        org.robolectric.util.ReflectionHelpers.setField(attached,"mWindowTop",p.y);
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
            float x = (control.getLeft() + control.getRight()) / 2f, y = (control.getTop()+control.getBottom())/2f;
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
        android.widget.TextView received=(android.widget.TextView)field(overlay,"count");
        android.widget.TextView staged=(android.widget.TextView)field(overlay,"shelfTab");
        assertEquals("1",received.getText().toString());
        assertEquals("0",staged.getText().toString());
        View receivedIcon=(View)field(overlay,"countIcon"),stagedIcon=(View)field(overlay,"shelfIcon");
        int gap=Math.round(4*header.getResources().getDisplayMetrics().density);
        assertEquals(gap,receivedIcon.getLeft()-received.getRight());
        assertEquals(gap,stagedIcon.getLeft()-staged.getRight());
        float x = (shelf.getLeft()+shelf.getRight())/2f, y=(shelf.getTop()+shelf.getBottom())/2f;
        touch(header, 0, MotionEvent.ACTION_DOWN, x, y);
        touch(header, 10, MotionEvent.ACTION_UP, x, y);
        Shadows.shadowOf(Looper.getMainLooper()).idle();
        assertTrue((Boolean)field(overlay,"shelfVisible"));
        int[] held = {0};
        bulk.setOnLongClickListener(view -> { held[0]++; return true; });
        x=(bulk.getLeft()+bulk.getRight())/2f;y=(bulk.getTop()+bulk.getBottom())/2f;
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
        android.graphics.Rect visual=(android.graphics.Rect)field(overlay,"visualBounds");
        assertTrue("intermediate visible width="+visual.width(),visual.width() < expandedWidth && visual.width() > Math.round(18*density));
        assertTrue("surface moves right while shrinking",visual.left > expandedX);
        assertEquals("OS window stays at the union origin throughout animation",expandedX,window.x);
        int envelopeWidth=window.width;
        advanceGeometry(overlay,120);
        assertEquals("no per-frame OS resize",envelopeWidth,window.width);
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
        visual=(android.graphics.Rect)field(overlay,"visualBounds");
        assertTrue(visual.width() > Math.round(18*density) && visual.width() < expandedWidth);
        assertTrue("expansion simultaneously moves left",visual.left < window.x+window.width-Math.round(18*density));
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
        View card=row.getChildAt(0);
        View remove=card.findViewWithTag("remove-item");
        assertEquals("移除",remove.getContentDescription());
        assertNull("remove has no background tile",remove.getBackground());
        assertEquals(Math.round(36*card.getResources().getDisplayMetrics().density),remove.getLayoutParams().width);
        ((android.widget.FrameLayout)card).getChildAt(((android.widget.FrameLayout)card).getChildCount()-1).performClick();
        assertEquals("已复制",org.robolectric.shadows.ShadowToast.getTextOfLatestToast());
        remove.performClick();
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
        View root=(View)field(overlay,"root");draw(root);root.getViewTreeObserver().dispatchOnPreDraw();
        android.animation.ValueAnimator animator=(android.animation.ValueAnimator)field(overlay,"geometry");
        assertNotNull("transition is active",animator);
        animator.setCurrentPlayTime(millis);
        if(millis>=animator.getDuration())animator.end();
        draw(root);root.getViewTreeObserver().dispatchOnPreDraw();
    }
    @Test public void bothEdgesMoveAndShrinkOnEveryPhaseOfTheSameClock() throws Exception {
        ReceiveOverlay overlay=create(new int[3]);
        org.robolectric.shadows.ShadowChoreographer.setPaused(true);
        View root=(View)field(overlay,"root");
        WindowManager.LayoutParams window=(WindowManager.LayoutParams)root.getLayoutParams();
        assertFalse("system must not append another position animation",window.canPlayMoveAnimation());
        android.graphics.Rect bounds=(android.graphics.Rect)field(overlay,"lastBounds");
        for(boolean right:new boolean[]{false,true}) {
            window.x=right?bounds.right-window.width-8:bounds.left+8;
            java.lang.reflect.Method render=ReceiveOverlay.class.getDeclaredMethod("render");render.setAccessible(true);render.invoke(overlay);
            draw(root);
            int originalWidth=window.width;float originalCenter=window.x+window.width/2f;
            float targetCenter=right?bounds.right-9:bounds.left+9;
            overlay.setCollapsed(true);int envelopeWidth=window.width;
            for(long time:new long[]{24,80,160}) {
                advanceGeometry(overlay,time);
                android.graphics.Rect visible=(android.graphics.Rect)field(overlay,"visualBounds");
                float shrinking=(originalWidth-visible.width())/(float)(originalWidth-18);
                float moving=(visible.exactCenterX()-originalCenter)/(targetCenter-originalCenter);
                assertTrue("starts shrinking immediately on "+right,shrinking>0 && shrinking<1);
                assertEquals("movement and size share progress on "+right,shrinking,moving,.035f);
                assertEquals(envelopeWidth,window.width);
            }
            capture(overlay,right?"right-simultaneous":"left-simultaneous");
            advanceGeometry(overlay,240);
            overlay.setCollapsed(false);advanceGeometry(overlay,24);
            android.graphics.Rect visible=(android.graphics.Rect)field(overlay,"visualBounds");
            assertTrue(visible.width()>18 && visible.width()<originalWidth);
            assertTrue(right?visible.exactCenterX()<targetCenter:visible.exactCenterX()>targetCenter);
            advanceGeometry(overlay,240);
        }
        overlay.hide();
    }
    @Test public void backgroundFollowsPressedOffsetButControlsAndFileDragKeepTheirGestures() throws Exception {
        int[] actions=new int[3];ReceiveOverlay overlay=create(actions);View root=(View)field(overlay,"root");
        ((View)field(overlay,"shelfTab")).performClick();draw(root);
        WindowManager.LayoutParams window=(WindowManager.LayoutParams)root.getLayoutParams();int x=window.x,y=window.y;
        touch(root,0,MotionEvent.ACTION_DOWN,20,50);touch(root,30,MotionEvent.ACTION_MOVE,-10,30);touch(root,60,MotionEvent.ACTION_UP,-10,30);
        assertEquals(x-30,window.x);assertEquals(y-20,window.y);assertArrayEquals(new int[3],actions);
        ((View)field(overlay,"count")).performClick();
        draw(root);View card=((LinearLayout)field(overlay,"row")).getChildAt(0);int[] dragged={0};
        card.setOnLongClickListener(view -> {dragged[0]++;return true;});
        touch(root,0,MotionEvent.ACTION_DOWN,20,40);
        Shadows.shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(ViewConfiguration.getLongPressTimeout()+100));
        touch(root,800,MotionEvent.ACTION_UP,20,40);
        assertEquals(1,dragged[0]);assertEquals(x-30,window.x);assertEquals(y-20,window.y);
        overlay.hide();
    }
    @Test public void edgeResizeKeepsOppositeEdgeAndNoExtraResizeControl() throws Exception {
        ReceiveOverlay overlay=create(new int[3]);View root=(View)field(overlay,"root");
        WindowManager.LayoutParams window=(WindowManager.LayoutParams)root.getLayoutParams();
        int x=window.x,width=window.width;
        touch(root,0,MotionEvent.ACTION_DOWN,1,50);touch(root,30,MotionEvent.ACTION_MOVE,-19,50);touch(root,60,MotionEvent.ACTION_UP,-19,50);
        assertEquals(x-20,window.x);assertEquals(width+20,window.width);assertEquals(x+width,window.x+window.width);
        draw(root);int height=window.height;
        touch(root,0,MotionEvent.ACTION_DOWN,50,height-1);touch(root,30,MotionEvent.ACTION_MOVE,50,height-101);touch(root,60,MotionEvent.ACTION_UP,50,height-101);
        assertEquals(92,window.height);
        LinearLayout header=(LinearLayout)field(overlay,"header");assertEquals(3,header.getChildCount());
        assertEquals(1,((View)field(overlay,"expanded")).getPaddingRight());overlay.hide();
    }
    @Test public void generousInvisibleResizeBandsLeaveButtonsAndCardCenterUsable() throws Exception {
        int[] actions=new int[3];ReceiveOverlay overlay=create(actions);View root=(View)field(overlay,"root");
        java.lang.reflect.Method edges=ReceiveOverlay.class.getDeclaredMethod("resizeEdges",float.class,float.class,int.class,int.class);
        edges.setAccessible(true);
        assertEquals(1,edges.invoke(overlay,10f,50f,232,116));
        assertEquals(5,edges.invoke(overlay,18f,18f,232,116));
        assertEquals(10,edges.invoke(overlay,214f,98f,232,116));
        assertEquals(0,edges.invoke(overlay,30f,50f,232,116));
        WindowManager.LayoutParams window=(WindowManager.LayoutParams)root.getLayoutParams();
        int width=window.width,x=window.x;
        touch(root,0,MotionEvent.ACTION_DOWN,10,50);touch(root,30,MotionEvent.ACTION_MOVE,-10,50);touch(root,60,MotionEvent.ACTION_UP,-10,50);
        assertEquals(width+20,window.width);assertEquals(x-20,window.x);draw(root);
        root.getViewTreeObserver().dispatchOnPreDraw();draw(root);
        View card=((LinearLayout)field(overlay,"row")).getChildAt(0);
        View remove=card.findViewWithTag("remove-item");
        android.graphics.Rect button=new android.graphics.Rect();remove.getDrawingRect(button);
        ((android.view.ViewGroup)root).offsetDescendantRectToMyCoords(remove,button);
        // The top of the delete target overlaps the enlarged top resize band.
        float bx=button.centerX(),by=button.top+1;
        java.lang.reflect.Method hitAction=ReceiveOverlay.class.getDeclaredMethod("hitsAction",View.class,MotionEvent.class);
        hitAction.setAccessible(true);
        MotionEvent point=MotionEvent.obtain(0,0,MotionEvent.ACTION_DOWN,bx,by,0);
        assertTrue("delete button must win over resize at "+button,(Boolean)hitAction.invoke(overlay,field(overlay,"surface"),point));point.recycle();
        touch(root,0,MotionEvent.ACTION_DOWN,bx,by);touch(root,10,MotionEvent.ACTION_UP,bx,by);
        Shadows.shadowOf(Looper.getMainLooper()).idle();
        assertEquals(0,((Map<?,?>)field(overlay,"items")).size());
        assertEquals(width+20,window.width);assertEquals(x-20,window.x);
        assertEquals(0f,((View)field(overlay,"surface")).getElevation(),0f);
        android.widget.HorizontalScrollView viewport=(android.widget.HorizontalScrollView)field(overlay,"scroll");
        assertEquals(0,((View)field(overlay,"expanded")).getPaddingLeft());
        assertFalse(viewport.getClipToPadding());assertEquals(4,viewport.getPaddingLeft());
        overlay.hide();
    }
    @Test @org.robolectric.annotation.GraphicsMode(org.robolectric.annotation.GraphicsMode.Mode.NATIVE)
    @Config(qualifiers="w393dp-h851dp-xxhdpi")
    public void scrolledCardsReachTheOuterGlassInsteadOfAnInsetRectangle() throws Exception {
        ReceiveOverlay overlay=create(new int[3]);View root=(View)field(overlay,"root");
        LinearLayout row=(LinearLayout)field(overlay,"row");
        View first=row.getChildAt(0);first.setBackgroundColor(0xff208fc6);
        ((android.widget.FrameLayout)first).getChildAt(0).setVisibility(View.INVISIBLE);
        android.widget.HorizontalScrollView viewport=(android.widget.HorizontalScrollView)field(overlay,"scroll");
        viewport.scrollTo(Math.round(24*root.getResources().getDisplayMetrics().density),0);
        android.graphics.Bitmap pixels=android.graphics.Bitmap.createBitmap(root.getWidth(),root.getHeight(),android.graphics.Bitmap.Config.ARGB_8888);
        root.draw(new android.graphics.Canvas(pixels));
        assertEquals("image continues to the outer left edge while scrolling",0xff208fc6,pixels.getPixel(1,root.getHeight()/2));
        assertEquals(0f,((View)field(overlay,"surface")).getElevation(),0f);
        capture(overlay,"scrolled-outer-edge");pixels.recycle();overlay.hide();
    }
    @Test public void receiptOpensCollapsedShelfAndCardsEnterAndExitIndependently() throws Exception {
        ReceiveOverlay overlay=create(new int[3]);View root=(View)field(overlay,"root");
        LinearLayout header=(LinearLayout)field(overlay,"header");assertEquals(LinearLayout.VERTICAL,header.getOrientation());
        android.graphics.Rect rail=new android.graphics.Rect();header.getDrawingRect(rail);((android.view.ViewGroup)root).offsetDescendantRectToMyCoords(header,rail);
        assertTrue("controls are at the right edge",rail.left>root.getWidth()/2);
        overlay.show(new ReceiveNotifications.Receipt("new","1","probe","new card",null,null,0),2,ignored -> {});
        LinearLayout row=(LinearLayout)field(overlay,"row");View incoming=row.getChildAt(0);
        assertEquals(0,incoming.getAlpha(),.001f);assertTrue(incoming.getTranslationY()<0);
        draw(root);root.getViewTreeObserver().dispatchOnPreDraw();
        Shadows.shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(220));assertEquals(1,incoming.getAlpha(),.001f);
        incoming.findViewWithTag("remove-item").performClick();
        assertEquals(1,((Map<?,?>)field(overlay,"items")).size());
        Shadows.shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(160));assertEquals(0,incoming.getAlpha(),.001f);
        org.robolectric.shadows.ShadowChoreographer.setPaused(true);overlay.setCollapsed(true);advanceGeometry(overlay,240);
        overlay.show(new ReceiveNotifications.Receipt("file","1","probe",null,"photo.png","/not-read.png",0),3,ignored -> {});
        assertFalse("arrival expands immediately without waiting for completion",(Boolean)field(overlay,"collapsed"));
        assertNotNull(field(overlay,"geometry"));advanceGeometry(overlay,240);overlay.hide();
    }
    @Test public void enabledShelfRestoresCollapsedOnNewRuntimeAndDisabledShelfStaysClosed() throws Exception {
        android.content.Context context=RuntimeEnvironment.getApplication();
        org.robolectric.shadows.ShadowSettings.setCanDrawOverlays(true);
        context.getSharedPreferences("received-popup-settings",0).edit().putBoolean("enabled",true).commit();
        ReceiveOverlay overlay=new ReceiveOverlay(context,new ReceiveOverlay.Actions() {
            public void open(String id){}public void copy(String id){}public void dismiss(Map<String,String> versions,long generation){}
        });
        Shadows.shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(250));
        View root=(View)field(overlay,"root");assertNotNull(root);
        assertTrue((Boolean)field(overlay,"collapsed"));
        assertEquals(Math.round(18*root.getResources().getDisplayMetrics().density),root.getLayoutParams().width);
        ReceiveOverlay.closeShelf();ReceiveOverlay.restoreShelf();assertNull(field(overlay,"root"));
    }
    @Test public void placementSizeAndModeRestoreBeforeFirstWindowAndKeepOrientationPositions() throws Exception {
        android.content.Context context=RuntimeEnvironment.getApplication();org.robolectric.shadows.ShadowSettings.setCanDrawOverlays(true);
        context.getSharedPreferences("received-popup-settings",0).edit().putBoolean("enabled",true).commit();
        ReceiveOverlay overlay=create(new int[3]);View root=(View)field(overlay,"root");
        ((View)field(overlay,"shelfTab")).performClick();draw(root);
        touch(root,0,MotionEvent.ACTION_DOWN,20,50);touch(root,30,MotionEvent.ACTION_MOVE,-100,-100);touch(root,60,MotionEvent.ACTION_UP,-100,-100);
        draw(root);WindowManager.LayoutParams window=(WindowManager.LayoutParams)root.getLayoutParams();int width=window.width,height=window.height;
        touch(root,0,MotionEvent.ACTION_DOWN,width-1,height-1);touch(root,30,MotionEvent.ACTION_MOVE,width+39,height+19);touch(root,60,MotionEvent.ACTION_UP,width+39,height+19);
        int x=window.x,y=window.y,w=window.width,h=window.height;overlay.hide();
        overlay=new ReceiveOverlay(context,new ReceiveOverlay.Actions(){public void open(String id){}public void copy(String id){}public void dismiss(Map<String,String> v,long g){}});
        Shadows.shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(250));root=(View)field(overlay,"root");
        window=(WindowManager.LayoutParams)root.getLayoutParams();assertEquals(x,window.x);assertEquals(y,window.y);assertEquals(w,window.width);assertEquals(h,window.height);
        assertFalse((Boolean)field(overlay,"collapsed"));
        android.graphics.Rect portrait=new android.graphics.Rect((android.graphics.Rect)field(overlay,"lastBounds"));
        android.graphics.Rect landscape=new android.graphics.Rect(0,24,1200,776);reflow(overlay,landscape);draw(root);
        int dx=200-window.x,dy=140-window.y;
        touch(root,0,MotionEvent.ACTION_DOWN,20,50);touch(root,30,MotionEvent.ACTION_MOVE,20+dx,50+dy);touch(root,60,MotionEvent.ACTION_UP,20+dx,50+dy);
        reflow(overlay,portrait);assertEquals(x,window.x);assertEquals(y,window.y);
        reflow(overlay,landscape);assertEquals(200,window.x);assertEquals(140,window.y);
        overlay.hide();
    }
    @Test public void appAlreadyForegroundRestoresHandleRatherThanFlashingSavedExpandedWindow() throws Exception {
        android.content.Context context=RuntimeEnvironment.getApplication();org.robolectric.shadows.ShadowSettings.setCanDrawOverlays(true);
        context.getSharedPreferences("received-popup-settings",0).edit().putBoolean("enabled",true).commit();
        context.getSharedPreferences("received-dock-placement",0).edit().putFloat("portrait.x",.25f).putFloat("portrait.y",.6f)
            .putBoolean("portrait.right",false).putBoolean("portrait.collapsed",false).putFloat("widthDp",272).putFloat("heightDp",136).commit();
        ReceiveOverlay overlay=new ReceiveOverlay(context,new ReceiveOverlay.Actions(){public void open(String id){}public void copy(String id){}public void dismiss(Map<String,String> v,long g){}});
        overlay.foreground();Shadows.shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(250));
        WindowManager.LayoutParams window=(WindowManager.LayoutParams)((View)field(overlay,"root")).getLayoutParams();
        assertTrue((Boolean)field(overlay,"collapsed"));assertEquals(18,window.width);assertEquals(0,window.x);
        assertEquals(272,field(overlay,"preferredWidth"));overlay.hide();
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
    @Test public void pullingHandleOpenDoesNotCollapseItAgainWhenFingerIsReleased() throws Exception {
        ReceiveOverlay overlay=create(new int[3]);
        org.robolectric.shadows.ShadowChoreographer.setPaused(true);
        WindowManager.LayoutParams window=(WindowManager.LayoutParams)((View)field(overlay,"root")).getLayoutParams();
        for(boolean right:new boolean[]{true,false}) {
            android.graphics.Rect bounds=(android.graphics.Rect)field(overlay,"lastBounds");
            window.x=right?bounds.right-window.width:bounds.left;
            overlay.setCollapsed(true);advanceGeometry(overlay,240);
            View handle=(View)field(overlay,"handle");
            touch(handle,0,MotionEvent.ACTION_DOWN,9,36);
            touch(handle,60,MotionEvent.ACTION_MOVE,right?-31:49,36);
            assertFalse((Boolean)field(overlay,"collapsed"));advanceGeometry(overlay,240);
            touch(handle,350,MotionEvent.ACTION_UP,right?-31:49,36);
            assertFalse("same UP must not reverse the completed expansion",(Boolean)field(overlay,"collapsed"));
            assertNull(field(overlay,"geometry"));
        }
        overlay.hide();
    }
    private void waitForImage(android.widget.ImageView image) throws Exception {
        for(int i=0;i<200 && image.getDrawable()==null;i++) {
            Shadows.shadowOf(Looper.getMainLooper()).idle();Thread.sleep(5);
        }
        assertNotNull("actual thumbnail decode completed",image.getDrawable());
    }
    @Test @org.robolectric.annotation.GraphicsMode(org.robolectric.annotation.GraphicsMode.Mode.NATIVE)
    public void imageFillsCardWithCropAndNoMetadataFooter() throws Exception {
        android.content.Context context=RuntimeEnvironment.getApplication();
        java.io.File file=new java.io.File(context.getFilesDir(),"full-card-fixture.png");
        android.graphics.Bitmap original=android.graphics.Bitmap.createBitmap(300,150,android.graphics.Bitmap.Config.ARGB_8888);
        android.graphics.Canvas canvas=new android.graphics.Canvas(original);canvas.drawColor(android.graphics.Color.YELLOW);
        android.graphics.Paint paint=new android.graphics.Paint();paint.setColor(android.graphics.Color.BLUE);canvas.drawRect(0,0,75,150,paint);
        paint.setColor(android.graphics.Color.RED);canvas.drawRect(225,0,300,150,paint);
        try(java.io.FileOutputStream out=new java.io.FileOutputStream(file)){original.compress(android.graphics.Bitmap.CompressFormat.PNG,100,out);}original.recycle();
        ReceiveOverlay overlay=create(new int[3]);
        overlay.show(new ReceiveNotifications.Receipt("image","1","source-not-a-footer",null,file.getName(),file.getPath(),file.length()),2,ignored -> {});
        View root=(View)field(overlay,"root");draw(root);root.getViewTreeObserver().dispatchOnPreDraw();
        android.widget.FrameLayout card=(android.widget.FrameLayout)((LinearLayout)field(overlay,"row")).getChildAt(0);
        android.widget.ImageView image=(android.widget.ImageView)card.getChildAt(0);waitForImage(image);
        assertEquals(0,card.getPaddingLeft());assertEquals(0,card.getPaddingTop());
        assertEquals(card.getWidth(),image.getWidth());assertEquals(card.getHeight(),image.getHeight());
        assertEquals(android.widget.ImageView.ScaleType.CENTER_CROP,image.getScaleType());
        android.graphics.Bitmap rendered=android.graphics.Bitmap.createBitmap(card.getWidth(),card.getHeight(),android.graphics.Bitmap.Config.ARGB_8888);
        card.draw(new android.graphics.Canvas(rendered));
        assertEquals("no reserved footer below the image",android.graphics.Color.YELLOW,rendered.getPixel(card.getWidth()/2,card.getHeight()-5));
        assertEquals("center crop removes source side bands",android.graphics.Color.YELLOW,rendered.getPixel(5,card.getHeight()/2));
        rendered.recycle();
        for(int i=0;i<card.getChildCount();i++)if(card.getChildAt(i) instanceof android.widget.TextView)
            assertEquals("×",((android.widget.TextView)card.getChildAt(i)).getText().toString());
        capture(overlay,"received-full-image");
        TemporaryShelf shelf=(TemporaryShelf)field(overlay,"shelf");shelf.add(java.util.List.of(file.getPath()),java.util.List.of("Text preview"),Map.of());
        ((View)field(overlay,"shelfTab")).performClick();draw(root);
        android.widget.FrameLayout staged=(android.widget.FrameLayout)((LinearLayout)field(overlay,"row")).getChildAt(0);
        waitForImage((android.widget.ImageView)staged.getChildAt(0));
        capture(overlay,"staged-full-image");
        ReceiveAppearance colors=ReceiveAppearance.load(context);
        assertNotEquals(colors.receivedAccent,colors.accent);assertNotEquals(colors.receivedSoft,colors.stagedSoft);
        overlay.hide();assertTrue(file.delete());
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
