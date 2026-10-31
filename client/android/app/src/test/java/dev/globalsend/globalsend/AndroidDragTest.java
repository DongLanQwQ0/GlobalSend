package dev.globalsend.globalsend;

import static org.junit.Assert.*;

import android.app.Activity;
import android.content.ClipData;
import android.content.ClipDescription;
import android.content.Context;
import android.content.ContentProvider;
import android.content.ContentValues;
import android.content.Intent;
import android.content.pm.ProviderInfo;
import android.database.Cursor;
import android.database.MatrixCursor;
import android.net.Uri;
import android.os.Looper;
import android.os.ParcelFileDescriptor;
import android.os.Parcel;
import android.provider.OpenableColumns;
import android.view.DragEvent;
import android.view.DragAndDropPermissions;
import android.view.MotionEvent;
import android.view.View;
import android.widget.FrameLayout;
import io.flutter.embedding.android.FlutterView;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.StandardMethodCodec;
import java.io.File;
import java.nio.ByteBuffer;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import org.junit.After;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.Robolectric;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.Shadows;
import org.robolectric.annotation.Config;
import org.robolectric.annotation.Implementation;
import org.robolectric.annotation.Implements;
import org.robolectric.shadows.ShadowContentResolver;
import org.robolectric.shadows.ShadowView;
import org.robolectric.util.ReflectionHelpers;

/** Android framework tests, not evidence of a physical cross-app gesture. */
@RunWith(RobolectricTestRunner.class)
@Config(sdk = 28, manifest = Config.NONE)
public class AndroidDragTest {
    private Activity activity;
    private DockCoordinator coordinator;
    private final List<MethodCall> events = new CopyOnWriteArrayList<>();

    @Before public void setUp() {
        activity = Robolectric.buildActivity(Activity.class).setup().get();
        BinaryMessenger messenger = new BinaryMessenger() {
            @Override public void send(String channel, ByteBuffer message) { send(channel, message, null); }
            @Override public void send(String channel, ByteBuffer message, BinaryReply callback) {
                ByteBuffer copy = message.duplicate(); copy.flip();
                events.add(StandardMethodCodec.INSTANCE.decodeMethodCall(copy));
            }
            @Override public void setMessageHandler(String channel, BinaryMessageHandler handler) {}
        };
        coordinator = new DockCoordinator(activity, new MethodChannel(messenger, "test-dock"));
    }

    @After public void tearDown() { coordinator.dispose(); activity.finish(); }

    private static DragEvent event(int action, ClipData clip) {
        DragEvent value = ReflectionHelpers.callConstructor(DragEvent.class);
        ReflectionHelpers.setField(value, "mAction", action);
        ReflectionHelpers.setField(value, "mClipDescription", clip.getDescription());
        ReflectionHelpers.setField(value, "mClipData", clip);
        return value;
    }

    private static DragEvent localEvent(int action, DockCoordinator.LocalDrag source, float x, float y) {
        DragEvent value = event(action, ClipData.newPlainText("local", source.text == null ? "file" : source.text));
        ReflectionHelpers.setField(value, "mLocalState", source);
        ReflectionHelpers.setField(value, "mX", x);
        ReflectionHelpers.setField(value, "mY", y);
        return value;
    }

    private void queueBounds() {
        coordinator.updateQueueDropBounds(Map.of("left", 20d, "top", 100d, "right", 350d, "bottom", 340d,
            "surfaceWidth", 393d, "surfaceHeight", 800d));
    }

    private long dropCount() { return events.stream().filter(call -> call.method.equals("nativeDrop")).count(); }

    @Test public void clipboardImportForShelfDoesNotBecomeAQueuedSend() throws Exception {
        activity.getSystemService(android.content.ClipboardManager.class).setPrimaryClip(ClipData.newPlainText("fixture","clipboard shelf text"));
        java.util.concurrent.atomic.AtomicReference<Map<String,Object>> received=new java.util.concurrent.atomic.AtomicReference<>();
        assertTrue(DockCoordinator.importClipboardToShelf(received::set));
        long deadline=System.currentTimeMillis()+5000;
        while(received.get()==null && System.currentTimeMillis()<deadline){Shadows.shadowOf(Looper.getMainLooper()).idle();Thread.sleep(5);}
        assertNotNull(received.get());assertEquals(List.of("clipboard shelf text"),received.get().get("texts"));
        assertEquals(0,dropCount());
        for(Object pending:(java.util.Collection<?>)ReflectionHelpers.getField(coordinator,"pending"))
            assertNotEquals(List.of("clipboard shelf text"),((Map<?,?>)pending).get("texts"));
    }

    @Test public void clipboardSuggestionLivesOnlyInShelfAndIsNeverBulkDragged() {
        ReceiveOverlay overlay=new ReceiveOverlay(activity,new ReceiveOverlay.Actions(){
            public void open(String id){}public void copy(String id){}public void dismiss(Map<String,String> versions,long generation){}
        });
        try {
            overlay.show(new ReceiveNotifications.Receipt("received","1","fixture","received text",null,null,0),1,shown -> {});
            activity.getSystemService(android.content.ClipboardManager.class).setPrimaryClip(ClipData.newPlainText("fixture","clipboard text"));
            ((View)ReflectionHelpers.getField(overlay,"shelfTab")).performClick();
            View row=ReflectionHelpers.getField(overlay,"row");
            assertNotNull(row.findViewWithTag("clipboard-suggestion"));assertTrue(overlay.bulkDragItems().isEmpty());
            assertTrue(((TemporaryShelf)ReflectionHelpers.getField(overlay,"shelf")).items.isEmpty());
            ((View)ReflectionHelpers.getField(overlay,"count")).performClick();
            assertNull(row.findViewWithTag("clipboard-suggestion"));assertEquals(1,overlay.bulkDragItems().size());
        } finally {overlay.hide();}
    }

    @Test public void mediaAndClipboardShareOneNewestFirstSuggestionZone() throws Exception {
        ReceiveOverlay overlay=new ReceiveOverlay(activity,new ReceiveOverlay.Actions(){
            public void open(String id){}public void copy(String id){}public void dismiss(Map<String,String> versions,long generation){}
        });
        try {
            overlay.show(new ReceiveNotifications.Receipt("received","1","fixture","received text",null,null,0),1,shown -> {});
            overlay.foreground();
            activity.getSystemService(android.content.ClipboardManager.class).setPrimaryClip(ClipData.newPlainText("fixture","clipboard candidate"));
            ((View)ReflectionHelpers.getField(overlay,"shelfTab")).performClick();
            TemporaryShelf shelf=ReflectionHelpers.getField(overlay,"shelf");
            shelf.add(List.of(),List.of("manual staged text"),Map.of());
            shelf.suggest(List.of(new RecentMediaSuggestions.Media("content://fixture/old","old.jpg",1)));
            ReceiveNotifications.Receipt old=shelf.items.values().stream().filter(item -> "old.jpg".equals(item.fileName)).findFirst().orElseThrow();
            long older=shelf.suggestedAt(old.id);
            Thread.sleep(25);
            shelf.suggest(List.of(new RecentMediaSuggestions.Media("content://fixture/new","new.jpg",2)));
            ReceiveNotifications.Receipt newest=shelf.items.values().stream().filter(item -> "new.jpg".equals(item.fileName)).findFirst().orElseThrow();
            assertTrue(shelf.suggestedAt(newest.id)>older);
            activity.getSharedPreferences("clipboard-suggestion",Context.MODE_PRIVATE).edit().putLong("suggestedAt",older+1).commit();
            ((View)ReflectionHelpers.getField(overlay,"shelfTab")).performClick();
            android.widget.LinearLayout row=ReflectionHelpers.getField(overlay,"row");
            List<String> order=new ArrayList<>();
            for(int i=0;i<row.getChildCount();i++) {
                Object tag=row.getChildAt(i).getTag();
                if("clipboard-suggestion".equals(tag))order.add("clipboard");
                else if(tag instanceof ReceiveNotifications.Receipt && shelf.isSuggested(((ReceiveNotifications.Receipt)tag).id))
                    order.add(((ReceiveNotifications.Receipt)tag).fileName);
            }
            assertEquals(List.of("new.jpg","clipboard","old.jpg"),order);
            assertEquals("open-app-space",row.getChildAt(2).getTag());
            assertEquals(1,overlay.bulkDragItems().size());
            assertEquals("manual staged text",overlay.bulkDragItems().get(0).text);
            shelf.suggest(List.of(new RecentMediaSuggestions.Media("content://fixture/old","old.jpg",1)));
            assertEquals(older,shelf.suggestedAt(old.id));
        } finally {overlay.hide();}
    }

    @Test public void clipboardOnlyShelfCanSwipePastOpeningSpaceWithoutMovingWindow() {
        ReceiveOverlay overlay=new ReceiveOverlay(activity,new ReceiveOverlay.Actions(){
            public void open(String id){}public void copy(String id){}public void dismiss(Map<String,String> versions,long generation){}
        });
        try {
            overlay.show(new ReceiveNotifications.Receipt("received","1","fixture","received text",null,null,0),1,shown -> {});
            activity.getSystemService(android.content.ClipboardManager.class)
                .setPrimaryClip(ClipData.newPlainText("fixture","unconfirmed clipboard text"));
            ((View)ReflectionHelpers.getField(overlay,"shelfTab")).performClick();
            View root=ReflectionHelpers.getField(overlay,"root");
            android.view.WindowManager.LayoutParams layout=(android.view.WindowManager.LayoutParams)root.getLayoutParams();
            root.measure(View.MeasureSpec.makeMeasureSpec(layout.width,View.MeasureSpec.EXACTLY),
                View.MeasureSpec.makeMeasureSpec(layout.height,View.MeasureSpec.EXACTLY));
            root.layout(0,0,layout.width,layout.height);
            root.getViewTreeObserver().dispatchOnPreDraw();
            Shadows.shadowOf(Looper.getMainLooper()).idleFor(java.time.Duration.ofMillis(600));
            android.widget.HorizontalScrollView scroll=ReflectionHelpers.getField(overlay,"scroll");
            TemporaryShelf shelf=ReflectionHelpers.getField(overlay,"shelf");
            assertTrue(shelf.items.isEmpty());
            assertNotNull(scroll.findViewWithTag("clipboard-suggestion"));
            assertTrue("Only an opening space and an unconfirmed suggestion still overflow",scroll.canScrollHorizontally(1));
            android.graphics.Rect bounds=new android.graphics.Rect();
            scroll.getDrawingRect(bounds);((android.view.ViewGroup)root).offsetDescendantRectToMyCoords(scroll,bounds);
            float left=bounds.left+bounds.width()*.2f,right=bounds.left+bounds.width()*.75f,y=bounds.exactCenterY();
            int windowX=layout.x,windowY=layout.y;
            swipeOverlay(root,right,left,y);
            assertTrue("The first swipe from the deliberately blank opening space must scroll",scroll.getScrollX()>0);
            int forwardOffset=scroll.getScrollX();
            swipeOverlay(root,left,right,y);
            assertTrue("A reverse swipe must scroll back",scroll.getScrollX()<forwardOffset);
            int reverseOffset=scroll.getScrollX();
            swipeOverlay(root,right,left,y);
            assertTrue("A second swipe must remain available",scroll.getScrollX()>reverseOffset);
            assertEquals(windowX,layout.x);assertEquals(windowY,layout.y);
            assertFalse((Boolean)ReflectionHelpers.getField(overlay,"collapsed"));
            assertTrue(shelf.items.isEmpty());assertTrue(overlay.bulkDragItems().isEmpty());assertEquals(0,dropCount());
        } finally {overlay.hide();}
    }

    @Test public void mediaExpiryFollowsTheRealViewportAndPausesDuringTouchAndNativeDrag() throws Exception {
        ReceiveOverlay overlay=new ReceiveOverlay(activity,new ReceiveOverlay.Actions(){
            public void open(String id){}public void copy(String id){}public void dismiss(Map<String,String> versions,long generation){}
        });
        try {
            overlay.show(new ReceiveNotifications.Receipt("received","1","fixture","received text",null,null,0),1,shown -> {});
            ((View)ReflectionHelpers.getField(overlay,"shelfTab")).performClick();
            TemporaryShelf shelf=ReflectionHelpers.getField(overlay,"shelf");
            shelf.suggest(List.of(new RecentMediaSuggestions.Media("content://fixture/visible","visible.jpg",1)));
            ReflectionHelpers.callInstanceMethod(overlay,"render",ReflectionHelpers.ClassParameter.from(boolean.class,false));
            View root=ReflectionHelpers.getField(overlay,"root");
            android.view.WindowManager.LayoutParams size=(android.view.WindowManager.LayoutParams)root.getLayoutParams();
            root.measure(View.MeasureSpec.makeMeasureSpec(size.width,View.MeasureSpec.EXACTLY),View.MeasureSpec.makeMeasureSpec(size.height,View.MeasureSpec.EXACTLY));
            root.layout(0,0,size.width,size.height);root.getViewTreeObserver().dispatchOnPreDraw();
            Shadows.shadowOf(Looper.getMainLooper()).idleFor(java.time.Duration.ofSeconds(40));
            assertEquals("The blank opening space must not spend the unseen card's budget",1,shelf.items.size());
            android.widget.HorizontalScrollView scroll=ReflectionHelpers.getField(overlay,"scroll");
            android.widget.LinearLayout row=ReflectionHelpers.getField(overlay,"row");
            String id=shelf.items.keySet().iterator().next();
            View card=row.getChildAt(row.getChildCount()-1);
            scroll.scrollTo(card.getLeft()-scroll.getWidth()+2,0);
            Shadows.shadowOf(Looper.getMainLooper()).idleFor(java.time.Duration.ofSeconds(40));
            assertEquals("A two-pixel sliver is not a viewed card",1,shelf.items.size());
            scroll.scrollTo(card.getLeft(),0);
            Shadows.shadowOf(Looper.getMainLooper()).idleFor(java.time.Duration.ofMillis(150));
            java.util.Set<String> visible=ReflectionHelpers.getField(shelf,"visibleSuggestions");
            assertTrue("The actual scrolled card must start its own budget",visible.contains(id));
            Shadows.shadowOf(Looper.getMainLooper()).idleFor(java.time.Duration.ofMillis(3000));
            long down=android.os.SystemClock.uptimeMillis();
            MotionEvent pressed=MotionEvent.obtain(down,down,MotionEvent.ACTION_DOWN,2,2,0);
            root.dispatchTouchEvent(pressed);pressed.recycle();
            Shadows.shadowOf(Looper.getMainLooper()).idleFor(java.time.Duration.ofSeconds(40));
            assertEquals("A held touch must not remove the card",1,shelf.items.size());
            MotionEvent released=MotionEvent.obtain(down,android.os.SystemClock.uptimeMillis(),MotionEvent.ACTION_CANCEL,2,2,0);
            root.dispatchTouchEvent(released);released.recycle();
            Shadows.shadowOf(Looper.getMainLooper()).idleFor(java.time.Duration.ofMillis(150));
            ClipData clip=ClipData.newPlainText("fixture","native drag");
            root.dispatchDragEvent(event(DragEvent.ACTION_DRAG_STARTED,clip));
            Map<String,Long> remaining=ReflectionHelpers.getField(shelf,"suggestionRemaining");
            long left=remaining.get(id);
            assertTrue("About three of the thirty visible seconds were used",left>=26_900 && left<=27_000);
            Shadows.shadowOf(Looper.getMainLooper()).idleFor(java.time.Duration.ofSeconds(40));
            assertEquals("The entire system drag remains protected",1,shelf.items.size());
            activity.sendBroadcast(new Intent(Intent.ACTION_SCREEN_OFF));Shadows.shadowOf(Looper.getMainLooper()).idle();
            root.dispatchDragEvent(event(DragEvent.ACTION_DRAG_ENDED,clip));
            Shadows.shadowOf(Looper.getMainLooper()).idleFor(java.time.Duration.ofSeconds(40));
            assertEquals("Screen-off time must not consume the remainder",1,shelf.items.size());
            activity.sendBroadcast(new Intent(Intent.ACTION_SCREEN_ON));Shadows.shadowOf(Looper.getMainLooper()).idle();
            Shadows.shadowOf(Looper.getMainLooper()).idleFor(java.time.Duration.ofMillis(left-1));assertEquals(1,shelf.items.size());
            Shadows.shadowOf(Looper.getMainLooper()).idleFor(java.time.Duration.ofMillis(1));assertTrue(shelf.items.isEmpty());
        } finally {overlay.hide();}
    }

    @Test public void collapsedDockDoesNotCountItsLaidOutSuggestionCards() {
        ReceiveOverlay overlay=new ReceiveOverlay(activity,new ReceiveOverlay.Actions(){
            public void open(String id){}public void copy(String id){}public void dismiss(Map<String,String> versions,long generation){}
        });
        try {
            overlay.show(new ReceiveNotifications.Receipt("received","1","fixture","received text",null,null,0),1,shown -> {});
            ((View)ReflectionHelpers.getField(overlay,"shelfTab")).performClick();
            TemporaryShelf shelf=ReflectionHelpers.getField(overlay,"shelf");
            shelf.suggest(List.of(new RecentMediaSuggestions.Media("content://fixture/collapsed","collapsed.jpg",1)));
            overlay.setCollapsed(true);
            View root=ReflectionHelpers.getField(overlay,"root");
            android.view.WindowManager.LayoutParams size=(android.view.WindowManager.LayoutParams)root.getLayoutParams();
            root.measure(View.MeasureSpec.makeMeasureSpec(size.width,View.MeasureSpec.EXACTLY),View.MeasureSpec.makeMeasureSpec(size.height,View.MeasureSpec.EXACTLY));
            root.layout(0,0,size.width,size.height);root.getViewTreeObserver().dispatchOnPreDraw();
            Shadows.shadowOf(Looper.getMainLooper()).idleFor(java.time.Duration.ofSeconds(40));
            assertEquals(1,shelf.items.size());
            java.util.Set<String> visible=ReflectionHelpers.getField(shelf,"visibleSuggestions");assertTrue(visible.isEmpty());
        } finally {overlay.hide();}
    }

    @Test public void clickingMediaSuggestionStagesItWithoutOpeningAndPreservesNativeLongPress() {
        AtomicInteger opens=new AtomicInteger();
        ReceiveOverlay overlay=new ReceiveOverlay(activity,new ReceiveOverlay.Actions(){
            public void open(String id){opens.incrementAndGet();}public void copy(String id){}public void dismiss(Map<String,String> versions,long generation){}
        });
        try {
            overlay.show(new ReceiveNotifications.Receipt("received","1","fixture","received text",null,null,0),1,shown -> {});
            ((View)ReflectionHelpers.getField(overlay,"shelfTab")).performClick();
            TemporaryShelf shelf=ReflectionHelpers.getField(overlay,"shelf");
            shelf.suggest(List.of(new RecentMediaSuggestions.Media("content://fixture/tap","tap.jpg",1)));
            ReceiveNotifications.Receipt item=shelf.items.values().iterator().next();
            android.widget.LinearLayout row=ReflectionHelpers.getField(overlay,"row");
            View card=row.findViewWithTag(item);assertNotNull(card);assertTrue(card.isLongClickable());
            assertTrue(card.performClick());assertEquals(0,opens.get());assertFalse(shelf.isSuggested(item.id));
            assertEquals(List.of(item),overlay.bulkDragItems());
            shelf.setVisibleSuggestions(java.util.Set.of(item.id));
            Shadows.shadowOf(Looper.getMainLooper()).idleFor(java.time.Duration.ofSeconds(40));
            assertTrue(shelf.items.containsKey(item.id));assertEquals(0,dropCount());
        } finally {overlay.hide();}
    }

    private void swipeOverlay(View root,float from,float to,float y) {
        long down=android.os.SystemClock.uptimeMillis();
        for(int step=0;step<=6;step++) {
            if(step>0)Shadows.shadowOf(Looper.getMainLooper()).idleFor(java.time.Duration.ofMillis(20));
            int action=step==0?MotionEvent.ACTION_DOWN:step==6?MotionEvent.ACTION_UP:MotionEvent.ACTION_MOVE;
            MotionEvent event=MotionEvent.obtain(down,android.os.SystemClock.uptimeMillis(),action,from+(to-from)*step/6,y,0);
            root.dispatchTouchEvent(event);event.recycle();
        }
    }

    @Test public void shelfClipboardCardRequiresConfirmationAndKeepsTheNextCopySuggested() throws Exception {
        ReceiveOverlay overlay=new ReceiveOverlay(activity,new ReceiveOverlay.Actions(){
            public void open(String id){}public void copy(String id){}public void dismiss(Map<String,String> versions,long generation){}
        });
        CountDownLatch release=new CountDownLatch(1);
        try {
            overlay.show(new ReceiveNotifications.Receipt("received","1","fixture","received text",null,null,0),1,shown -> {});
            overlay.foreground();
            var clipboard=activity.getSystemService(android.content.ClipboardManager.class);
            clipboard.setPrimaryClip(ClipData.newPlainText("fixture","confirmed shelf candidate"));
            ((View)ReflectionHelpers.getField(overlay,"shelfTab")).performClick();
            View row=ReflectionHelpers.getField(overlay,"row"),card=row.findViewWithTag("clipboard-suggestion");
            TemporaryShelf shelf=ReflectionHelpers.getField(overlay,"shelf");
            assertNotNull(card);assertFalse(card.isLongClickable());assertTrue(shelf.items.isEmpty());
            assertTrue(overlay.bulkDragItems().isEmpty());assertEquals(0,dropCount());
            java.util.concurrent.ExecutorService importer=ReflectionHelpers.getField(coordinator,"importer");
            importer.execute(() -> {try {release.await(5,TimeUnit.SECONDS);}catch(InterruptedException error){Thread.currentThread().interrupt();}});
            card.performClick();
            clipboard.setPrimaryClip(ClipData.newPlainText("fixture","next unconfirmed copy"));
            release.countDown();
            long deadline=System.currentTimeMillis()+5000;
            while(shelf.items.isEmpty()&&System.currentTimeMillis()<deadline){Shadows.shadowOf(Looper.getMainLooper()).idle();Thread.sleep(5);}
            Shadows.shadowOf(Looper.getMainLooper()).idle();
            assertEquals(1,shelf.items.size());assertEquals("confirmed shelf candidate",overlay.bulkDragItems().get(0).text);
            assertNotNull(row.findViewWithTag("clipboard-suggestion"));assertEquals("text",DockCoordinator.clipboardSuggestion().get("kind"));
            assertEquals(0,dropCount());
        } finally {release.countDown();overlay.hide();}
    }

    @Test public void externalAndLocalHoverReportTheDeviceInsteadOfOnlyTheQueue() {
        queueBounds();
        coordinator.updateDeviceDropBounds("center",List.of(
            Map.of("deviceId","phone","left",20d,"top",400d,"right",100d,"bottom",480d),
            Map.of("deviceId","tablet","left",120d,"top",400d,"right",200d,"bottom",480d)));
        for(boolean local:new boolean[]{false,true}) {
            DockCoordinator.LocalDrag source=new DockCoordinator.LocalDrag(new View(activity),List.of(),List.of("hello"));
            for(float x:new float[]{50,150}) {
                DragEvent hover=local?localEvent(DragEvent.ACTION_DRAG_LOCATION,source,x,440):event(DragEvent.ACTION_DRAG_LOCATION,ClipData.newPlainText("external","hello"));
                ReflectionHelpers.setField(hover,"mX",x);ReflectionHelpers.setField(hover,"mY",440f);
                assertTrue(coordinator.acceptDrag(hover));
                Map<?,?> state=(Map<?,?>)events.get(events.size()-1).arguments;
                assertEquals(x==50?"phone":"tablet",state.get("targetDeviceId"));
                assertEquals(true,state.get("active"));
                int published=events.size();
                ReflectionHelpers.setField(hover,"mX",x+1);
                coordinator.acceptDrag(hover);
                assertEquals("Movement within one device must not rebuild Flutter every frame",published,events.size());
            }
            DragEvent leave=local?localEvent(DragEvent.ACTION_DRAG_EXITED,source,0,0):event(DragEvent.ACTION_DRAG_EXITED,ClipData.newPlainText("external","hello"));
            coordinator.acceptDrag(leave);
            Map<?,?> cleared=(Map<?,?>)events.get(events.size()-1).arguments;
            assertEquals(false,cleared.get("active"));assertEquals("",cleared.get("targetDeviceId"));
        }
    }

    @Test public void droppingOnADeviceCarriesOnlyThatDestinationAndOriginalBatch() {
        queueBounds();
        coordinator.updateDeviceDropBounds("center", List.of(Map.of("deviceId","target-uuid", "left",20d,"top",400d,"right",100d,"bottom",480d)));
        assertEquals("target-uuid",coordinator.deviceDropAt(50,440));
        assertEquals("",coordinator.deviceDropAt(200,440));
        DockCoordinator.LocalDrag source=new DockCoordinator.LocalDrag(new View(activity),List.of("content://media/external/images/media/77"),List.of("hello"));
        coordinator.acceptDrag(localEvent(DragEvent.ACTION_DRAG_STARTED,source,0,0));
        assertTrue(coordinator.acceptDrag(localEvent(DragEvent.ACTION_DROP,source,50,440)));
        Map<?,?> drop=(Map<?,?>)events.stream().filter(call->call.method.equals("nativeDrop")).findFirst().get().arguments;
        assertEquals("target-uuid",drop.get("targetDeviceId"));assertEquals("center",drop.get("serverKey"));
        assertEquals(List.of("content://media/external/images/media/77"),drop.get("paths"));
        assertEquals(List.of("hello"),drop.get("texts"));
        coordinator.updateDeviceDropBounds("center",List.of());assertEquals("",coordinator.deviceDropAt(50,440));
    }

    @Implements(View.class)
    public static class NativeDragView extends ShadowView {
        static boolean allowed;
        static final List<ClipData> clips = new ArrayList<>();
        static final List<Object> states = new ArrayList<>();
        @Implementation protected boolean startDragAndDrop(ClipData clip, View.DragShadowBuilder shadow, Object state, int flags) {
            clips.add(clip); states.add(state); return allowed;
        }
        @Implementation protected void cancelDragAndDrop() { }
        static void resetFixture() { allowed = true; clips.clear(); states.clear(); }
    }

    @Test @Config(shadows = NativeDragView.class)
    public void nativeSessionsReleaseAfterEndAndDeclineOnlyLiveReentry() throws Exception {
        NativeDragView.resetFixture();
        View source = new View(activity);
        activity.setContentView(source);
        assertTrue(DockCoordinator.startDrag(source, null, "第一条", "文本"));
        DockCoordinator.LocalDrag first = (DockCoordinator.LocalDrag) NativeDragView.states.get(0);
        assertFalse(DockCoordinator.startDrag(source, null, "第二条", "文本"));
        assertEquals(1, NativeDragView.states.size());
        coordinator.acceptDrag(localEvent(DragEvent.ACTION_DRAG_ENDED, first, 0, 0));
        assertTrue(DockCoordinator.startDrag(source, null, "第二条", "文本"));
        DockCoordinator.LocalDrag second = (DockCoordinator.LocalDrag) NativeDragView.states.get(1);
        coordinator.acceptDrag(localEvent(DragEvent.ACTION_DRAG_ENDED, second, 0, 0));
        assertTrue(DockCoordinator.startDrag(source, null, "第三条", "文本"));
        assertEquals(3, NativeDragView.states.size());
    }

    @Test @Config(sdk=34,shadows=NativeDragView.class)
    public void shelfExportOutcomeUsesNativeAcceptanceAndKeepsReturnedContent() throws Exception {
        NativeDragView.resetFixture();View source=new View(activity);activity.setContentView(source);
        List<Boolean> completed=new ArrayList<>();
        assertTrue(DockCoordinator.startDrag(source,List.of(),List.of("第一项","第二项"),"2 项",completed::add));
        assertEquals(2,NativeDragView.clips.get(0).getItemCount());
        DockCoordinator.LocalDrag first=(DockCoordinator.LocalDrag)NativeDragView.states.get(0);
        DragEvent ended=localEvent(DragEvent.ACTION_DRAG_ENDED,first,0,0);
        ReflectionHelpers.setField(ended,"mDragResult",true);coordinator.acceptDrag(ended);
        assertEquals(List.of(true),completed);
        assertTrue(DockCoordinator.startDrag(source,List.of(),List.of("回投"),"1 项",completed::add));
        DockCoordinator.LocalDrag second=(DockCoordinator.LocalDrag)NativeDragView.states.get(1);
        List<Map<String,Object>> returned=new ArrayList<>();
        assertTrue(DockCoordinator.importToShelf(localEvent(DragEvent.ACTION_DROP,second,0,0),returned::add));
        ended=localEvent(DragEvent.ACTION_DRAG_ENDED,second,0,0);ReflectionHelpers.setField(ended,"mDragResult",true);
        coordinator.acceptDrag(ended);
        assertEquals(List.of(true,false),completed);assertEquals(List.of("回投"),returned.get(0).get("texts"));assertEquals(0,dropCount());
    }

    @Test @Config(shadows = NativeDragView.class)
    public void bulkSystemDragIncludesEveryFileAndTextAndReturnsThemToQueueWithoutImportCopies() throws Exception {
        NativeDragView.resetFixture();View source=new View(activity);activity.setContentView(source);queueBounds();
        List<String> paths=new ArrayList<>();for(int i=0;i<70;i++){File file=new File(activity.getFilesDir(),"drag"+i+".bin");Files.write(file.toPath(),("content"+i).getBytes(java.nio.charset.StandardCharsets.UTF_8));paths.add(file.getPath());}
        assertTrue(DockCoordinator.startDrag(source,paths,List.of("first","second"),"72 项"));
        assertEquals(72,NativeDragView.clips.get(0).getItemCount());
        DockCoordinator.LocalDrag local=(DockCoordinator.LocalDrag)NativeDragView.states.get(0);
        coordinator.acceptDrag(localEvent(DragEvent.ACTION_DRAG_STARTED,local,0,0));
        assertTrue(coordinator.acceptDrag(localEvent(DragEvent.ACTION_DROP,local,100,200)));
        MethodCall drop=events.stream().filter(call->call.method.equals("nativeDrop")).findFirst().get();Map<?,?> value=(Map<?,?>)drop.arguments;
        assertEquals(paths,value.get("paths"));assertEquals(List.of("first","second"),value.get("texts"));assertTrue(((List<?>)value.get("temporaryPaths")).isEmpty());
        coordinator.acceptDrag(localEvent(DragEvent.ACTION_DRAG_ENDED,local,0,0));
    }
    @Test public void externalBulkDropImportsMoreThanThirtyTwoUrisWithoutTruncating() throws Exception {
        DockShareProvider provider=new DockShareProvider();ProviderInfo info=new ProviderInfo();info.authority=activity.getPackageName()+".dock-files";provider.attachInfo(activity,info);ShadowContentResolver.registerProviderInternal(info.authority,provider);
        List<Uri> uris=new ArrayList<>();for(int i=0;i<70;i++){File file=new File(activity.getFilesDir(),"external"+i+".bin");Files.write(file.toPath(),("bytes"+i).getBytes(java.nio.charset.StandardCharsets.UTF_8));uris.add(DockShareProvider.register(activity,file,file.getName()));}
        ClipData clip=ClipData.newUri(activity.getContentResolver(),"70 files",uris.get(0));for(int i=1;i<uris.size();i++)clip.addItem(new ClipData.Item(uris.get(i)));
        assertTrue(coordinator.acceptDrag(event(DragEvent.ACTION_DROP,clip)));Map<?,?> imported=awaitDrop();
        assertNull(imported.get("error"));assertEquals(70,((List<?>)imported.get("paths")).size());assertEquals(70,((List<?>)imported.get("temporaryPaths")).size());
    }

    @Test @Config(shadows = NativeDragView.class)
    public void refusedSystemStartIsReportedAndDoesNotPoisonTheNextDrag() throws Exception {
        NativeDragView.resetFixture();
        View source = new View(activity);
        NativeDragView.allowed = false;
        try {
            DockCoordinator.startDrag(source, null, "未开始", "文本");
            fail("An actual failed system start must still be reported");
        } catch (IllegalStateException expected) {
            assertTrue(expected.getMessage().contains("开始拖放"));
        }
        NativeDragView.allowed = true;
        assertTrue(DockCoordinator.startDrag(source, null, "可以重试", "文本"));
    }

    @Test @Config(shadows = NativeDragView.class)
    public void overlayDragReturnsAcrossViewRootsWithoutLocalStateOrCopy() throws Exception {
        NativeDragView.resetFixture(); queueBounds();
        View overlaySource = new View(activity);
        assertTrue(DockCoordinator.startDrag(overlaySource, null, "从悬浮接收坞回投", "文本"));
        ClipData clip = NativeDragView.clips.get(0);
        // A different ViewRoot receives the same ClipDescription but no localState.
        assertTrue(coordinator.acceptDrag(event(DragEvent.ACTION_DRAG_STARTED, clip)));
        DragEvent drop = event(DragEvent.ACTION_DROP, clip);
        ReflectionHelpers.setField(drop, "mX", 40f); ReflectionHelpers.setField(drop, "mY", 150f);
        assertTrue(coordinator.acceptDrag(drop));
        Map<?, ?> imported = awaitDrop();
        assertEquals(List.of("从悬浮接收坞回投"), imported.get("texts"));
        assertEquals(List.of(), imported.get("temporaryPaths"));
        DragEvent ended = event(DragEvent.ACTION_DRAG_ENDED, clip);
        ReflectionHelpers.setField(ended, "mClipDescription", null);
        coordinator.acceptDrag(ended);
        assertTrue(DockCoordinator.startDrag(overlaySource, null, "下一次", "文本"));
    }

    @Test @Config(shadows = NativeDragView.class)
    public void overlaySourceWindowStaysAttachedUntilTheSystemDragEnds() throws Exception {
        NativeDragView.resetFixture();
        ReceiveOverlay overlay = new ReceiveOverlay(activity, new ReceiveOverlay.Actions() {
            public void open(String id) { }
            public void copy(String id) { }
            public void dismiss(Map<String, String> versions, long generation) { }
        });
        overlay.show(new ReceiveNotifications.Receipt("one", "1", "电脑", "回投正文", null, null, 0), 1, shown -> { });
        Shadows.shadowOf(Looper.getMainLooper()).idle();
        View root = ReflectionHelpers.getField(overlay, "root");
        android.widget.LinearLayout row = ReflectionHelpers.getField(overlay, "row");
        android.widget.FrameLayout card = (android.widget.FrameLayout) row.getChildAt(0);
        View source = new View(activity);
        card.addView(source, new android.widget.FrameLayout.LayoutParams(1, 1));
        assertTrue(root.isAttachedToWindow());
        assertTrue(DockCoordinator.startDrag(source, null, "回投正文", "文本"));
        assertEquals(true, coordinator.status().get("localSessionActive"));
        overlay.hide(); // The Activity becoming foreground must not destroy its drag source.
        assertSame(root, ReflectionHelpers.getField(overlay, "root"));
        assertTrue(root.isAttachedToWindow());
        DockCoordinator.LocalDrag local = (DockCoordinator.LocalDrag) NativeDragView.states.get(0);
        coordinator.acceptDrag(localEvent(DragEvent.ACTION_DRAG_ENDED, local, 0, 0));
        assertNull(ReflectionHelpers.getField(overlay, "root"));
        // The current source is released immediately, but the old view stays
        // attached for its 150 ms exit animation before independent removal.
        Shadows.shadowOf(Looper.getMainLooper()).idleFor(180, TimeUnit.MILLISECONDS);
        assertFalse(root.isAttachedToWindow());
        assertEquals(false, coordinator.status().get("localSessionActive"));
    }

    @Test @Config(shadows = NativeDragView.class)
    public void incomingOverlayUpdateDoesNotDetachTheActiveDragCard() throws Exception {
        NativeDragView.resetFixture();
        ReceiveOverlay overlay = new ReceiveOverlay(activity, new ReceiveOverlay.Actions() {
            public void open(String id) { }
            public void copy(String id) { }
            public void dismiss(Map<String, String> versions, long generation) { }
        });
        overlay.show(new ReceiveNotifications.Receipt("one", "1", "电脑", "拖动中", null, null, 0), 1, shown -> { });
        Shadows.shadowOf(Looper.getMainLooper()).idle();
        View root = ReflectionHelpers.getField(overlay, "root");
        android.widget.LinearLayout row = ReflectionHelpers.getField(overlay, "row");
        android.widget.FrameLayout card = (android.widget.FrameLayout) row.getChildAt(0);
        View source = new View(activity);
        card.addView(source, new android.widget.FrameLayout.LayoutParams(1, 1));
        assertTrue(DockCoordinator.startDrag(source, null, "拖动中", "文本"));
        overlay.show(new ReceiveNotifications.Receipt("two", "1", "手机", "新内容", null, null, 0), 2, shown -> { });
        assertEquals(3, row.getChildCount()); // one card, clear, open-app space
        assertSame(card, row.getChildAt(0));
        assertTrue(source.isAttachedToWindow());
        DockCoordinator.LocalDrag local = (DockCoordinator.LocalDrag) NativeDragView.states.get(0);
        coordinator.acceptDrag(localEvent(DragEvent.ACTION_DRAG_ENDED, local, 0, 0));
        assertSame(root, ReflectionHelpers.getField(overlay, "root"));
        assertEquals(4, row.getChildCount()); // two cards, clear, open-app space
        overlay.hide();
    }

    private void navigationBounds() {
        coordinator.updateSendNavigationBounds(Map.of("left", 196d, "top", 732d, "right", 393d, "bottom", 800d,
            "surfaceWidth", 393d, "surfaceHeight", 800d));
    }
    private long navigationCount() {
        return events.stream().filter(call -> call.method.equals("nativeDrag") && "send".equals(((Map<?, ?>) call.arguments).get("navigate"))).count();
    }

    @Test public void onlyDeliberateSendTabHoverNavigatesAndThenQueueAcceptsTheDrop() throws Exception {
        navigationBounds();
        DockCoordinator.LocalDrag local = new DockCoordinator.LocalDrag(new View(activity), null, "跨页回投");
        coordinator.acceptDrag(localEvent(DragEvent.ACTION_DRAG_STARTED, local, 0, 0));
        coordinator.acceptDrag(localEvent(DragEvent.ACTION_DRAG_LOCATION, local, 100, 700));
        Shadows.shadowOf(Looper.getMainLooper()).idleFor(java.time.Duration.ofMillis(400));
        assertEquals(0, navigationCount());
        coordinator.acceptDrag(localEvent(DragEvent.ACTION_DRAG_LOCATION, local, 250, 750));
        Shadows.shadowOf(Looper.getMainLooper()).idleFor(java.time.Duration.ofMillis(349));
        assertEquals(0, navigationCount());
        Shadows.shadowOf(Looper.getMainLooper()).idleFor(java.time.Duration.ofMillis(1));
        assertEquals(1, navigationCount());
        assertFalse(coordinator.acceptDrag(localEvent(DragEvent.ACTION_DROP, local, 250, 750)));
        assertEquals(0, dropCount());
        queueBounds();
        coordinator.acceptDrag(localEvent(DragEvent.ACTION_DRAG_LOCATION, local, 40, 150));
        assertTrue(coordinator.acceptDrag(localEvent(DragEvent.ACTION_DROP, local, 40, 150)));
        assertEquals(List.of("跨页回投"), awaitDrop().get("texts"));
    }

    @Test public void leavingNavigationOrEndingTheSessionCancelsTheHoverTimer() {
        navigationBounds();
        DockCoordinator.LocalDrag local = new DockCoordinator.LocalDrag(new View(activity), null, "不切页");
        coordinator.acceptDrag(localEvent(DragEvent.ACTION_DRAG_STARTED, local, 0, 0));
        coordinator.acceptDrag(localEvent(DragEvent.ACTION_DRAG_LOCATION, local, 250, 750));
        Shadows.shadowOf(Looper.getMainLooper()).idleFor(java.time.Duration.ofMillis(200));
        coordinator.acceptDrag(localEvent(DragEvent.ACTION_DRAG_LOCATION, local, 100, 700));
        Shadows.shadowOf(Looper.getMainLooper()).idleFor(java.time.Duration.ofMillis(400));
        assertEquals(0, navigationCount());
        coordinator.acceptDrag(localEvent(DragEvent.ACTION_DRAG_LOCATION, local, 250, 750));
        coordinator.acceptDrag(localEvent(DragEvent.ACTION_DRAG_ENDED, local, 250, 750));
        Shadows.shadowOf(Looper.getMainLooper()).idleFor(java.time.Duration.ofMillis(400));
        assertEquals(0, navigationCount());
        assertEquals(0, dropCount());
    }

    @Test public void nativeLocalTextParticipatesButOnlyTheQueueAcceptsItOnce() throws Exception {
        queueBounds();
        DockCoordinator.LocalDrag local = new DockCoordinator.LocalDrag(new View(activity), null, "系统拖动的原文");
        assertTrue(coordinator.acceptDrag(localEvent(DragEvent.ACTION_DRAG_STARTED, local, 0, 0)));
        assertTrue(coordinator.acceptDrag(localEvent(DragEvent.ACTION_DRAG_LOCATION, local, 40, 150)));
        assertEquals(true, coordinator.status().get("queueActive"));
        assertEquals(false, coordinator.status().get("active")); // no full-window shade.
        assertTrue(coordinator.acceptDrag(localEvent(DragEvent.ACTION_DROP, local, 40, 150)));
        Map<?, ?> drop = awaitDrop();
        assertEquals(List.of("系统拖动的原文"), drop.get("texts"));
        assertEquals(List.of(), drop.get("paths"));
        assertEquals(List.of(), drop.get("temporaryPaths"));
        assertEquals(true, drop.get("local"));
        assertFalse(coordinator.acceptDrag(localEvent(DragEvent.ACTION_DROP, local, 40, 150)));
        assertEquals(1, dropCount());
        coordinator.acceptDrag(localEvent(DragEvent.ACTION_DRAG_ENDED, local, 40, 150));
        assertEquals(false, coordinator.status().get("queueActive"));
    }

    @Test public void nativeLocalFilesAndSafKeepTheOriginalReferenceWithoutImportCopy() throws Exception {
        queueBounds();
        for (String path : List.of(new File(activity.getFilesDir(), "已保存.png").getPath(), "content://received-fixture/document/原图")) {
            events.clear();
            DockCoordinator.LocalDrag local = new DockCoordinator.LocalDrag(new View(activity), path, null);
            assertTrue(coordinator.acceptDrag(localEvent(DragEvent.ACTION_DROP, local, 40, 150)));
            Map<?, ?> drop = awaitDrop();
            assertEquals(List.of(path), drop.get("paths"));
            assertEquals(List.of(), drop.get("texts"));
            assertEquals(List.of(), drop.get("temporaryPaths"));
            assertEquals(false, coordinator.status().get("importing"));
        }
    }

    @Test public void localOutsideOrHiddenQueueNeverStagesOrTriggersAnImport() {
        queueBounds();
        DockCoordinator.LocalDrag outside = new DockCoordinator.LocalDrag(new View(activity), null, "不应加入");
        coordinator.acceptDrag(localEvent(DragEvent.ACTION_DRAG_STARTED, outside, 0, 0));
        for (float[] point : new float[][]{{10, 150}, {350, 150}, {40, 340}, {40, 80}})
            assertFalse(coordinator.acceptDrag(localEvent(DragEvent.ACTION_DROP, outside, point[0], point[1])));
        coordinator.updateQueueDropBounds(null);
        assertFalse(coordinator.acceptDrag(localEvent(DragEvent.ACTION_DROP, outside, 40, 150)));
        coordinator.acceptDrag(localEvent(DragEvent.ACTION_DRAG_ENDED, outside, 40, 150));
        assertEquals(0, dropCount());
        assertEquals(false, coordinator.status().get("importing"));
        assertEquals(false, coordinator.status().get("queueActive"));
    }

    @Test public void movedOrResizedQueueImmediatelyStopsAcceptingStaleCoordinates() {
        queueBounds();
        DockCoordinator.LocalDrag local = new DockCoordinator.LocalDrag(new View(activity), null, "范围更新");
        coordinator.acceptDrag(localEvent(DragEvent.ACTION_DRAG_LOCATION, local, 40, 150));
        assertEquals(true, coordinator.status().get("queueActive"));
        coordinator.updateQueueDropBounds(Map.of("left", 20d, "top", 300d, "right", 350d, "bottom", 540d,
            "surfaceWidth", 393d, "surfaceHeight", 800d));
        assertEquals(false, coordinator.status().get("queueActive"));
        assertFalse(coordinator.acceptDrag(localEvent(DragEvent.ACTION_DROP, local, 40, 150)));
        assertTrue(coordinator.acceptDrag(localEvent(DragEvent.ACTION_DROP, local, 40, 350)));
    }

    private Map<?, ?> awaitDrop() throws Exception {
        long deadline = System.currentTimeMillis() + 5000;
        while (System.currentTimeMillis() < deadline) {
            Shadows.shadowOf(Looper.getMainLooper()).idle();
            for (MethodCall call : events) if (call.method.equals("nativeDrop")) return (Map<?, ?>) call.arguments;
            Thread.sleep(10);
        }
        throw new AssertionError("Native import did not complete");
    }

    @Test public void listenerIsOnPassiveLeafInsideFlutterViewNotSharedContentContainer() {
        FrameLayout nested = new FrameLayout(activity);
        FlutterView flutter = new FlutterView(activity);
        nested.addView(flutter); activity.setContentView(nested);
        activity.findViewById(android.R.id.content).setOnDragListener((view, event) -> { throw new AssertionError("Plugin listener still owns the drop"); });
        coordinator.attachDragReceiver();
        assertSame(flutter, DockCoordinator.findFlutterView(activity.findViewById(android.R.id.content)));
        View receiver = flutter.getChildAt(flutter.getChildCount() - 1);
        assertEquals(View.class, receiver.getClass());
        assertFalse(receiver.isClickable()); assertFalse(receiver.isFocusable());
        int children = flutter.getChildCount(); coordinator.attachDragReceiver(); assertEquals(children, flutter.getChildCount());
        ClipData text = ClipData.newPlainText("text", "拖入文字");
        assertTrue(receiver.dispatchDragEvent(event(DragEvent.ACTION_DRAG_STARTED, text)));
        assertTrue(receiver.dispatchDragEvent(event(DragEvent.ACTION_DRAG_ENTERED, text)));
        assertEquals(true, ((Map<?, ?>) events.get(events.size() - 1).arguments).get("active"));
        assertTrue(receiver.dispatchDragEvent(event(DragEvent.ACTION_DRAG_EXITED, text)));
        assertEquals(false, coordinator.status().get("active"));
        coordinator.dispose(); assertEquals(children - 1, flutter.getChildCount());
    }

    @Test public void passiveDragLeafDoesNotStealTouchSequenceFromFlutterSurface() {
        List<Integer> touches = new ArrayList<>();
        FlutterView flutter = new FlutterView(activity) {
            @Override public boolean onTouchEvent(MotionEvent event) {
                touches.add(event.getActionMasked());
                return true;
            }
        };
        activity.setContentView(flutter);
        coordinator.attachDragReceiver();
        flutter.measure(View.MeasureSpec.makeMeasureSpec(800, View.MeasureSpec.EXACTLY),
            View.MeasureSpec.makeMeasureSpec(600, View.MeasureSpec.EXACTLY));
        flutter.layout(0, 0, 800, 600);
        View receiver = flutter.getChildAt(flutter.getChildCount() - 1);
        assertEquals(800, receiver.getWidth());
        assertEquals(600, receiver.getHeight());
        assertFalse(receiver.isFocusableInTouchMode());
        assertEquals(View.IMPORTANT_FOR_ACCESSIBILITY_NO, receiver.getImportantForAccessibility());
        long now = android.os.SystemClock.uptimeMillis();
        for (int action : new int[]{MotionEvent.ACTION_DOWN, MotionEvent.ACTION_MOVE, MotionEvent.ACTION_UP}) {
            MotionEvent input = MotionEvent.obtain(now, now + touches.size() * 10, action, 120, 180, 0);
            try { assertTrue(flutter.dispatchTouchEvent(input)); }
            finally { input.recycle(); }
        }
        assertEquals(List.of(MotionEvent.ACTION_DOWN, MotionEvent.ACTION_MOVE, MotionEvent.ACTION_UP), touches);
        assertTrue(events.isEmpty());
    }

    @Test public void replacingFlutterSurfaceRemovesOldLeafAndClearsHoverWithoutLosingImportState() {
        FlutterView first = new FlutterView(activity);
        activity.setContentView(first);
        coordinator.resumed();
        View oldReceiver = first.getChildAt(first.getChildCount() - 1);
        coordinator.acceptDrag(event(DragEvent.ACTION_DRAG_ENTERED, ClipData.newPlainText("text", "draft")));
        assertEquals(true, coordinator.status().get("active"));
        FlutterView replacement = new FlutterView(activity);
        activity.setContentView(replacement);
        coordinator.resumed();
        assertNull(oldReceiver.getParent());
        assertEquals(false, coordinator.status().get("active"));
        int children = replacement.getChildCount();
        coordinator.resumed();
        assertEquals(children, replacement.getChildCount());
        coordinator.dispose();
        assertEquals(children - 1, replacement.getChildCount());
    }

    @Test @Config(shadows = TrackingPermissions.class)
    public void dropGrantIsHeldWhileSourceStreamIsOpenAndReleasedAfterCopy() throws Exception {
        TrackingPermissions.releases.set(0);
        BlockingProvider provider = new BlockingProvider();
        ProviderInfo info = new ProviderInfo(); info.authority = "blocking-fixture";
        provider.attachInfo(activity, info);
        ShadowContentResolver.registerProviderInternal(info.authority, provider);
        Parcel parcel = Parcel.obtain();
        DragAndDropPermissions grant;
        try {
            parcel.writeStrongBinder(null); parcel.setDataPosition(0);
            grant = DragAndDropPermissions.CREATOR.createFromParcel(parcel);
        } finally { parcel.recycle(); }
        // The normal activity owns storage and a real source resolver. Override
        // only the Android-issued capability returned at the DROP boundary.
        coordinator.dispose();
        activity.finish();
        GrantActivity sourceActivity = Robolectric.buildActivity(GrantActivity.class).setup().get();
        sourceActivity.grant = grant;
        activity = sourceActivity;
        BinaryMessenger messenger = new BinaryMessenger() {
            @Override public void send(String channel, ByteBuffer message) { send(channel, message, null); }
            @Override public void send(String channel, ByteBuffer message, BinaryReply callback) {
                ByteBuffer copy = message.duplicate(); copy.flip();
                events.add(StandardMethodCodec.INSTANCE.decodeMethodCall(copy));
            }
            @Override public void setMessageHandler(String channel, BinaryMessageHandler handler) {}
        };
        coordinator = new DockCoordinator(sourceActivity, new MethodChannel(messenger, "test-dock"));
        Uri uri = Uri.parse("content://blocking-fixture/held.txt");
        ClipData clip = new ClipData("held", new String[]{"text/plain"}, new ClipData.Item(uri));
        assertTrue(coordinator.acceptDrag(event(DragEvent.ACTION_DROP, clip)));
        assertTrue(provider.opened.await(5, TimeUnit.SECONDS));
        assertEquals(0, TrackingPermissions.releases.get());
        assertEquals(true, coordinator.status().get("importing"));
        provider.continueCopy.countDown();
        Map<?, ?> drop = awaitDrop();
        assertNull(drop.get("error"));
        File imported = new File((String) ((List<?>) drop.get("paths")).get(0));
        assertArrayEquals(new byte[]{4, 5, 6}, Files.readAllBytes(imported.toPath()));
        assertEquals(1, TrackingPermissions.releases.get());
        assertEquals(false, coordinator.status().get("importing"));
    }

    @Implements(DragAndDropPermissions.class)
    public static class TrackingPermissions {
        static final AtomicInteger releases = new AtomicInteger();
        @Implementation protected void release() { releases.incrementAndGet(); }
    }

    public static class GrantActivity extends Activity {
        DragAndDropPermissions grant;
        @Override public DragAndDropPermissions requestDragAndDropPermissions(DragEvent event) { return grant; }
    }

    public static class BlockingProvider extends FixtureProvider {
        final CountDownLatch opened = new CountDownLatch(1), continueCopy = new CountDownLatch(1);
        @Override public Cursor query(Uri uri, String[] projection, String selection, String[] args, String order) {
            MatrixCursor result = new MatrixCursor(new String[]{OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE});
            result.addRow(new Object[]{"held.txt", 3}); return result;
        }
        @Override public ParcelFileDescriptor openFile(Uri uri, String mode) throws java.io.FileNotFoundException {
            opened.countDown();
            try {
                if (!continueCopy.await(5, TimeUnit.SECONDS)) throw new java.io.IOException("Test stream not released");
                File source = new File(getContext().getCacheDir(), "held-source.txt");
                Files.write(source.toPath(), new byte[]{4, 5, 6});
                return ParcelFileDescriptor.open(source, ParcelFileDescriptor.MODE_READ_ONLY);
            } catch (Exception e) { throw new java.io.FileNotFoundException(e.toString()); }
        }
    }

    @Test public void dragSnapshotsResetHoverAndKeepImportStateUntilComplete() throws Exception {
        ClipData text = ClipData.newPlainText("text", "独立待发文本");
        coordinator.acceptDrag(event(DragEvent.ACTION_DRAG_STARTED, text));
        coordinator.acceptDrag(event(DragEvent.ACTION_DRAG_ENTERED, text));
        coordinator.acceptDrag(event(DragEvent.ACTION_DRAG_EXITED, text));
        assertEquals(false, coordinator.status().get("active"));
        assertTrue(coordinator.acceptDrag(event(DragEvent.ACTION_DROP, text)));
        assertEquals(true, coordinator.status().get("importing"));
        coordinator.acceptDrag(event(DragEvent.ACTION_DRAG_ENDED, text));
        assertEquals(true, coordinator.status().get("importing"));
        Map<?, ?> drop = awaitDrop();
        assertEquals(List.of("独立待发文本"), drop.get("texts"));
        assertEquals(false, coordinator.status().get("active"));
        assertEquals(false, coordinator.status().get("importing"));
        for (MethodCall call : events) if (call.method.equals("nativeDrag")) {
            Map<?, ?> state = (Map<?, ?>) call.arguments;
            assertTrue(state.containsKey("active")); assertTrue(state.containsKey("importing"));
        }
    }

    @Test public void multipleContentUrisCopyChineseAndEmptyFilesToAppOwnedStaging() throws Exception {
        FixtureProvider provider = new FixtureProvider();
        provider.directory = new File(activity.getCacheDir(), "source-fixtures"); provider.directory.mkdirs();
        Files.write(new File(provider.directory, "中文文件.txt").toPath(), "文件正文".getBytes(java.nio.charset.StandardCharsets.UTF_8));
        Files.write(new File(provider.directory, "empty.bin").toPath(), new byte[0]);
        Files.write(new File(provider.directory, "chunk.bin").toPath(), new byte[150000]);
        ProviderInfo info = new ProviderInfo(); info.authority = "fixtures"; provider.attachInfo(activity, info);
        ShadowContentResolver.registerProviderInternal("fixtures", provider);
        ArrayList<Uri> uris = new ArrayList<>();
        for (String name : List.of("中文文件.txt", "empty.bin", "chunk.bin")) uris.add(new Uri.Builder().scheme("content").authority("fixtures").appendPath(name).build());
        Intent intent = new Intent(Intent.ACTION_SEND_MULTIPLE).setType("*/*").putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris);
        coordinator.handleSharedIntent(intent);
        Map<?, ?> event = awaitDrop();
        assertNull(event.get("error"));
        List<?> paths = (List<?>) event.get("paths"); assertEquals(3, paths.size());
        for (int i = 0; i < paths.size(); i++) {
            File saved = new File((String) paths.get(i));
            assertTrue(saved.getCanonicalPath().startsWith(activity.getFilesDir().getCanonicalPath() + File.separator));
            File expected = new File(provider.directory, uris.get(i).getLastPathSegment());
            assertEquals(expected.getName(), saved.getName());
            assertArrayEquals(Files.readAllBytes(expected.toPath()), Files.readAllBytes(saved.toPath()));
        }
        assertNull(intent.getAction());
    }

    @Test @Config(sdk=34) public void dragExportAdvertisesRealImageMimeAndReadOnlyBytes() throws Exception {
        File image = new File(activity.getFilesDir(), "照片.PNG"); byte[] bytes = {1, 2, 3}; Files.write(image.toPath(), bytes);
        Uri uri = DockShareProvider.register(activity, image, image.getName());
        DockShareProvider provider = new DockShareProvider();
        assertEquals("image/png", provider.getType(uri));
        assertEquals("text/plain", DockShareProvider.mimeType("笔记.TXT"));
        assertEquals("application/pdf", DockShareProvider.mimeType("设计稿.pdf"));
        try (ParcelFileDescriptor descriptor = provider.openFile(uri, "r")) {
            assertArrayEquals(bytes, new java.io.FileInputStream(descriptor.getFileDescriptor()).readAllBytes());
        }
        try { provider.openFile(uri, "w"); fail("Write access must not be exported"); }
        catch (java.io.FileNotFoundException expected) {}
    }

    @Test @Config(sdk=34,shadows = NativeDragView.class)
    public void savedPublicDownloadCanStartSystemDragAndReturnOriginalWithoutCopy() throws Exception {
        NativeDragView.resetFixture();
        File directory = new File(android.os.Environment.getExternalStoragePublicDirectory(
            android.os.Environment.DIRECTORY_DOWNLOADS), "GlobalSend");
        assertTrue(directory.isDirectory() || directory.mkdirs());
        File image = new File(directory, "IMG_20261026_181405 (1).jpg");
        byte[] bytes = {1, 3, 5, 7}; Files.write(image.toPath(), bytes);
        assertTrue(image.isFile() && image.canRead());
        assertFalse(image.getCanonicalPath().startsWith(activity.getDataDir().getCanonicalPath() + File.separator));
        assertFalse(image.getCanonicalPath().startsWith(activity.getExternalFilesDir(null).getCanonicalPath() + File.separator));
        DockShareProvider provider = new DockShareProvider();
        ProviderInfo info = new ProviderInfo(); info.authority = activity.getPackageName() + ".dock-files";
        provider.attachInfo(activity, info); ShadowContentResolver.registerProviderInternal(info.authority, provider);
        View source = new View(activity); activity.setContentView(source); queueBounds();
        assertTrue(DockCoordinator.startDrag(source, image.getPath(), null, image.getName()));
        Uri uri = NativeDragView.clips.get(0).getItemAt(0).getUri();
        try (java.io.InputStream stream = activity.getContentResolver().openInputStream(uri)) {
            assertArrayEquals(bytes, stream.readAllBytes());
        }
        DockCoordinator.LocalDrag local = (DockCoordinator.LocalDrag) NativeDragView.states.get(0);
        coordinator.acceptDrag(localEvent(DragEvent.ACTION_DRAG_STARTED, local, 0, 0));
        assertTrue(coordinator.acceptDrag(localEvent(DragEvent.ACTION_DROP, local, 100, 200)));
        Map<?, ?> imported = awaitDrop();
        assertEquals(List.of(image.getPath()), imported.get("paths"));
        assertEquals(List.of(), imported.get("temporaryPaths"));
        coordinator.acceptDrag(localEvent(DragEvent.ACTION_DRAG_ENDED, local, 0, 0));
        assertArrayEquals(bytes, Files.readAllBytes(image.toPath()));
        try { provider.openFile(uri, "w"); fail("Drag grants read access only"); }
        catch (java.io.FileNotFoundException expected) { }
    }

    @Test @Config(sdk=34,shadows = NativeDragView.class)
    public void bulkPublicFileDragKeepsEachOriginalNameForOtherApps() throws Exception {
        NativeDragView.resetFixture();
        DockShareProvider provider = new DockShareProvider();
        ProviderInfo info = new ProviderInfo(); info.authority = activity.getPackageName() + ".dock-files";
        provider.attachInfo(activity, info); ShadowContentResolver.registerProviderInternal(info.authority, provider);
        File directory = new File(android.os.Environment.getExternalStoragePublicDirectory(
            android.os.Environment.DIRECTORY_DOWNLOADS), "GlobalSend");
        assertTrue(directory.isDirectory() || directory.mkdirs());
        List<String> names = List.of("课程笔记.txt", "照片.jpg");
        List<String> paths = new ArrayList<>();
        for (String name : names) {
            File file = new File(directory, name);
            Files.write(file.toPath(), name.getBytes(java.nio.charset.StandardCharsets.UTF_8));
            paths.add(file.getPath());
        }
        View source = new View(activity); activity.setContentView(source);
        assertTrue(DockCoordinator.startDrag(source, paths, List.of(), "2 项"));
        ClipData clip = NativeDragView.clips.get(0);
        assertEquals("2 项", clip.getDescription().getLabel());
        for (int i = 0; i < names.size(); i++) {
            Uri uri = clip.getItemAt(i).getUri();
            try (Cursor cursor = activity.getContentResolver().query(uri,
                    new String[]{OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE}, null, null, null)) {
                assertNotNull(cursor); assertTrue(cursor.moveToFirst());
                assertEquals(names.get(i), cursor.getString(0));
                assertEquals(new File(paths.get(i)).length(), cursor.getLong(1));
            }
            try (java.io.InputStream stream = activity.getContentResolver().openInputStream(uri)) {
                assertArrayEquals(Files.readAllBytes(new File(paths.get(i)).toPath()), stream.readAllBytes());
            }
        }
        coordinator.acceptDrag(localEvent(DragEvent.ACTION_DRAG_ENDED,
            (DockCoordinator.LocalDrag) NativeDragView.states.get(0), 0, 0));
    }

    public static class FixtureProvider extends ContentProvider {
        File directory;
        @Override public boolean onCreate() { return true; }
        @Override public String getType(Uri uri) { return "application/octet-stream"; }
        @Override public Cursor query(Uri uri, String[] projection, String selection, String[] args, String order) {
            File file = new File(directory, uri.getLastPathSegment());
            MatrixCursor cursor = new MatrixCursor(new String[]{OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE});
            cursor.addRow(new Object[]{file.getName(), file.length()}); return cursor;
        }
        @Override public ParcelFileDescriptor openFile(Uri uri, String mode) throws java.io.FileNotFoundException {
            return ParcelFileDescriptor.open(new File(directory, uri.getLastPathSegment()), ParcelFileDescriptor.MODE_READ_ONLY);
        }
        @Override public Uri insert(Uri uri, ContentValues value) { throw new UnsupportedOperationException(); }
        @Override public int update(Uri uri, ContentValues value, String selection, String[] args) { throw new UnsupportedOperationException(); }
        @Override public int delete(Uri uri, String selection, String[] args) { throw new UnsupportedOperationException(); }
    }
}
