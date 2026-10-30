package dev.globalsend.globalsend;

import static org.junit.Assert.*;
import android.app.Activity;
import android.content.ClipData;
import android.content.Intent;
import android.graphics.Rect;
import android.os.Looper;
import android.view.DragEvent;
import android.view.MotionEvent;
import android.view.View;
import android.view.WindowManager;
import android.widget.HorizontalScrollView;
import android.widget.LinearLayout;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.StandardMethodCodec;
import java.nio.ByteBuffer;
import java.time.Duration;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import org.junit.After;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.Robolectric;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;
import org.robolectric.Shadows;
import org.robolectric.annotation.Config;
import org.robolectric.util.ReflectionHelpers;

/** Framework gestures/channel checks; physical OEM drag acceptance is separate. */
@RunWith(RobolectricTestRunner.class)
@Config(sdk=34,manifest=Config.NONE,qualifiers="w800dp-h1200dp",shadows=AndroidDragTest.NativeDragView.class)
public class ReceiveOverlayDeviceTargetsTest {
    private Activity activity;
    private DockCoordinator coordinator;
    private ReceiveOverlay overlay;
    private View root;
    private MethodCall sent;
    private BinaryMessenger.BinaryReply reply;
    private Object field(Object owner,String name) throws Exception {
        return ReflectionHelpers.getField(owner,name);
    }
    @Before public void setUp() throws Exception {
        // A continuously reposted frame callback needs the real asynchronous
        // VSync clock, not Robolectric's immediate recursive VSync default.
        org.robolectric.shadows.ShadowChoreographer.setPaused(true);
        activity=Robolectric.buildActivity(Activity.class).setup().get();
        coordinator=new DockCoordinator(activity,new MethodChannel(new BinaryMessenger() {
            public void send(String channel,ByteBuffer message) {send(channel,message,null);}
            public void send(String channel,ByteBuffer message,BinaryReply callback) {
                ByteBuffer copy=message.duplicate();copy.flip();
                MethodCall call=StandardMethodCodec.INSTANCE.decodeMethodCall(copy);
                if(call.method.equals("sendToDevice")){sent=call;reply=callback;}
            }
            public void setMessageHandler(String channel,BinaryMessageHandler handler) { }
        },"dock-test"));
        overlay=new ReceiveOverlay(RuntimeEnvironment.getApplication(),new ReceiveOverlay.Actions() {
            public void open(String id) {fail("Blank-space gestures must not open an item");}
            public void copy(String id) {fail("Blank-space gestures must not copy an item");}
            public void dismiss(Map<String,String> versions,long generation) { }
        });
        overlay.show(new ReceiveNotifications.Receipt("received","1","电脑","收到的文字",null,null,0),1,ignored -> {});
        idle(250);root=(View)field(overlay,"root");draw();
        root.getViewTreeObserver().dispatchOnPreDraw();idle(250);
        AndroidDragTest.NativeDragView.resetFixture();
    }
    @After public void tearDown() {coordinator.dispose();overlay.hide();activity.finish();}
    private void idle(long millis) {Shadows.shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(millis));}
    private void draw() {
        WindowManager.LayoutParams size=(WindowManager.LayoutParams)root.getLayoutParams();
        Object attached=ReflectionHelpers.getField(root,"mAttachInfo");
        ReflectionHelpers.setField(attached,"mWindowLeft",size.x);ReflectionHelpers.setField(attached,"mWindowTop",size.y);
        root.measure(View.MeasureSpec.makeMeasureSpec(size.width,View.MeasureSpec.EXACTLY),View.MeasureSpec.makeMeasureSpec(size.height,View.MeasureSpec.EXACTLY));
        root.layout(0,0,size.width,size.height);
    }
    private Rect bounds(View view) {
        Rect bounds=new Rect();view.getDrawingRect(bounds);((android.view.ViewGroup)root).offsetDescendantRectToMyCoords(view,bounds);return bounds;
    }
    private void tap(Rect area) {
        long now=android.os.SystemClock.uptimeMillis();
        for(int action:new int[]{MotionEvent.ACTION_DOWN,MotionEvent.ACTION_UP}) {
            MotionEvent event=MotionEvent.obtain(now,now+(action==MotionEvent.ACTION_UP?10:0),action,area.centerX(),area.centerY(),0);
            root.dispatchTouchEvent(event);event.recycle();
        }
    }
    private boolean drag(int action,float x,float y,boolean result) throws Exception {
        DragEvent event=ReflectionHelpers.callConstructor(DragEvent.class);
        int index=AndroidDragTest.NativeDragView.clips.size()-1;
        ClipData clip=AndroidDragTest.NativeDragView.clips.get(index);
        ReflectionHelpers.setField(event,"mAction",action);ReflectionHelpers.setField(event,"mX",x);ReflectionHelpers.setField(event,"mY",y);
        ReflectionHelpers.setField(event,"mLocalState",AndroidDragTest.NativeDragView.states.get(index));
        ReflectionHelpers.setField(event,"mClipDescription",clip.getDescription());ReflectionHelpers.setField(event,"mClipData",clip);
        ReflectionHelpers.setField(event,"mDragResult",result);
        if(action==DragEvent.ACTION_DRAG_STARTED || action==DragEvent.ACTION_DRAG_EXITED || action==DragEvent.ACTION_DRAG_ENDED) {
            java.lang.reflect.Method receive=ReceiveOverlay.class.getDeclaredMethod("receiveDrop",DragEvent.class);receive.setAccessible(true);
            return (Boolean)receive.invoke(overlay,event);
        }
        return root.dispatchDragEvent(event);
    }
    private void targets() {
        List<Map<String,String>> devices=new ArrayList<>();
        for(int i=0;i<8;i++)devices.add(Map.of("deviceId","id-"+i,"name",i<2?"同名设备":"设备 "+i,"platform",i%2==0?"windows":"android"));
        devices.add(devices.get(0));coordinator.updateSendTargets("center",devices);
    }
    private TemporaryShelf begin() throws Exception {return begin(false);}
    private TemporaryShelf begin(boolean all) throws Exception {
        TemporaryShelf shelf=(TemporaryShelf)field(overlay,"shelf");shelf.add(List.of(),List.of("本次发送","保留的另一项"),Map.of());
        ((View)field(overlay,"shelfTab")).performClick();draw();
        // Robolectric's startDragAndDrop shadow is attached to View, not the
        // framework's FrameLayout shadow. Invoke the same production exporter
        // with an attached View; native completion is simulated above.
        View source=new View(activity);((android.widget.FrameLayout)root).addView(source,new android.widget.FrameLayout.LayoutParams(1,1));
        java.lang.reflect.Method export=ReceiveOverlay.class.getDeclaredMethod("export",View.class,List.class);export.setAccessible(true);
        assertTrue((Boolean)export.invoke(overlay,source,all?new ArrayList<>(shelf.items.values()):List.of(shelf.items.values().iterator().next())));
        Object listeners=ReflectionHelpers.getField(source,"mListenerInfo");
        assertTrue("root must stay the innermost interested drag target",listeners==null || ReflectionHelpers.getField(listeners,"mOnDragListener")==null);
        assertTrue(drag(DragEvent.ACTION_DRAG_STARTED,25,55,false));
        drag(DragEvent.ACTION_DRAG_EXITED,-1,55,false);draw();idle(150);
        assertTrue("system drag source stays attached",source.isAttachedToWindow());
        assertEquals(View.VISIBLE,((View)field(overlay,"targetScroll")).getVisibility());return shelf;
    }
    private void capture(String name) throws Exception {
        String outputDirectory=System.getenv("GLOBALSEND_DOCK_TEST_ARTIFACTS");if(outputDirectory==null)return;
        java.io.File directory=new java.io.File(outputDirectory);directory.mkdirs();
        android.graphics.Bitmap image=android.graphics.Bitmap.createBitmap(root.getWidth()*3,root.getHeight()*3,android.graphics.Bitmap.Config.ARGB_8888);
        android.graphics.Canvas canvas=new android.graphics.Canvas(image);canvas.drawColor(0xffe9ecef);canvas.scale(3,3);root.draw(canvas);
        try(java.io.OutputStream output=new java.io.FileOutputStream(new java.io.File(directory,name+".jpg"))) {
            image.compress(android.graphics.Bitmap.CompressFormat.JPEG,90,output);
        }
        image.recycle();
    }
    @org.robolectric.annotation.GraphicsMode(org.robolectric.annotation.GraphicsMode.Mode.NATIVE)
    @Test public void fullSquareAfterClearIsBlankAndDoubleTapOpensAppForBothLists() throws Exception {
        android.content.Context context=RuntimeEnvironment.getApplication();
        android.content.pm.ResolveInfo launcher=new android.content.pm.ResolveInfo();launcher.activityInfo=new android.content.pm.ActivityInfo();
        launcher.activityInfo.packageName=context.getPackageName();launcher.activityInfo.name="test.GlobalSendActivity";
        launcher.activityInfo.applicationInfo=new android.content.pm.ApplicationInfo();launcher.activityInfo.applicationInfo.packageName=context.getPackageName();
        Shadows.shadowOf(context.getPackageManager()).addResolveInfoForIntent(new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER).setPackage(context.getPackageName()),launcher);
        TemporaryShelf shelf=(TemporaryShelf)field(overlay,"shelf");shelf.add(List.of(),List.of("暂存"),Map.of());
        for(boolean staged:new boolean[]{false,true}) {
            ((View)field(overlay,staged?"shelfTab":"count")).performClick();draw();
            LinearLayout row=(LinearLayout)field(overlay,"row");View blank=row.getChildAt(row.getChildCount()-1);
            assertEquals("open-app-space",blank.getTag());assertNull(blank.getBackground());
            assertEquals(row.getChildAt(0).getWidth(),blank.getWidth());assertEquals(blank.getWidth(),blank.getHeight());
            assertEquals("清空当前列表",row.getChildAt(row.getChildCount()-2).getContentDescription());
            ((HorizontalScrollView)field(overlay,"scroll")).scrollTo(row.getWidth(),0);
            Rect area=bounds(blank);assertTrue(area.centerX()<((View)field(overlay,"scroll")).getRight());
            if(staged)capture("tail-blank");
            tap(area);idle(50);tap(area);idle(400);
            assertEquals("test.GlobalSendActivity",Shadows.shadowOf(RuntimeEnvironment.getApplication()).getNextStartedActivity().getComponent().getClassName());
            assertEquals(1,shelf.items.size());assertEquals(1,((Map<?,?>)field(overlay,"items")).size());
        }
    }
    @Test @org.robolectric.annotation.GraphicsMode(org.robolectric.annotation.GraphicsMode.Mode.NATIVE)
    public void dragOutShowsDeduplicatedTargetsAutoScrollsBothWaysAndSendsOnlySelectedItem() throws Exception {
        targets();TemporaryShelf shelf=begin();
        LinearLayout row=(LinearLayout)field(overlay,"targetRow");assertEquals(8,row.getChildCount());
        capture("device-strip");
        HorizontalScrollView viewport=(HorizontalScrollView)field(overlay,"targetScroll");
        drag(DragEvent.ACTION_DRAG_LOCATION,root.getWidth()-8,55,false);frames(1_000_000_000L,150);
        int right=viewport.getScrollX();assertTrue("hovering right keeps scrolling without new motion",right>0);
        drag(DragEvent.ACTION_DRAG_LOCATION,8,55,false);frames(1_150_000_000L,150);assertTrue(viewport.getScrollX()<right);
        viewport.scrollTo(0,0);Rect first=bounds(row.getChildAt(1));
        assertTrue(drag(DragEvent.ACTION_DROP,first.centerX(),first.centerY(),false));assertNotNull(sent);
        assertEquals("id-1",sent.argument("deviceId"));assertEquals("center",sent.argument("serverKey"));
        assertEquals(List.of("本次发送"),sent.argument("texts"));assertEquals(List.of(),sent.argument("paths"));
        drag(DragEvent.ACTION_DRAG_ENDED,0,0,true);
        assertEquals(View.GONE,viewport.getVisibility());assertEquals(1f,((View)field(overlay,"expanded")).getAlpha(),0);
        ByteBuffer success=StandardMethodCodec.INSTANCE.encodeSuccessEnvelope(null);success.flip();reply.reply(success);
        assertEquals(3,shelf.removalSeconds());idle(3100);assertEquals(1,shelf.items.size());
        assertEquals("保留的另一项",shelf.items.values().iterator().next().text);
    }
    @Test public void cancelledDragAndRejectedSendRestoreContentsWithoutRemoval() throws Exception {
        targets();TemporaryShelf shelf=begin();drag(DragEvent.ACTION_DRAG_ENDED,0,0,false);
        assertEquals(0,shelf.removalSeconds());assertEquals(2,shelf.items.size());
        begin();LinearLayout row=(LinearLayout)field(overlay,"targetRow");Rect first=bounds(row.getChildAt(0));
        assertTrue(drag(DragEvent.ACTION_DROP,first.centerX(),first.centerY(),false));
        drag(DragEvent.ACTION_DRAG_ENDED,0,0,true);
        ByteBuffer error=StandardMethodCodec.INSTANCE.encodeErrorEnvelope("OFFLINE","offline",null);error.flip();reply.reply(error);
        idle(3100);assertEquals(2,shelf.items.size());assertEquals(0,shelf.removalSeconds());
    }
    @Test public void bulkDropSendsWholeSelectionAndLeavesReceivedRecordsUntouched() throws Exception {
        targets();TemporaryShelf shelf=begin(true);
        Rect first=bounds(((LinearLayout)field(overlay,"targetRow")).getChildAt(0));
        assertTrue(drag(DragEvent.ACTION_DROP,first.centerX(),first.centerY(),false));
        assertEquals(List.of("本次发送","保留的另一项"),sent.argument("texts"));
        drag(DragEvent.ACTION_DRAG_ENDED,0,0,true);
        ByteBuffer success=StandardMethodCodec.INSTANCE.encodeSuccessEnvelope(null);success.flip();reply.reply(success);
        assertEquals(3,shelf.removalSeconds());idle(3100);assertTrue(shelf.items.isEmpty());
        assertEquals(1,((Map<?,?>)field(overlay,"items")).size());
    }
    private void frames(long start,int millis) throws Exception {
        android.view.Choreographer.FrameCallback callback=(android.view.Choreographer.FrameCallback)field(overlay,"targetAutoScroll");
        for(int i=0;i<=millis;i+=10)callback.doFrame(start+i*1_000_000L);
    }
    private int scrollFrames(int hertz,float x) throws Exception {
        HorizontalScrollView viewport=(HorizontalScrollView)field(overlay,"targetScroll");
        drag(DragEvent.ACTION_DRAG_LOCATION,root.getWidth()/2f,55,false);viewport.scrollTo(200,0);
        drag(DragEvent.ACTION_DRAG_LOCATION,x,55,false);
        android.view.Choreographer.FrameCallback frames=(android.view.Choreographer.FrameCallback)field(overlay,"targetAutoScroll");
        for(int i=0;i<=hertz/2;i++)frames.doFrame(1_000_000_000L+Math.round(i*1_000_000_000d/hertz));
        int distance=viewport.getScrollX()-200;
        drag(DragEvent.ACTION_DRAG_LOCATION,root.getWidth()/2f,55,false);
        int stopped=viewport.getScrollX();idle(100);assertEquals("leaving the edge stops immediately",stopped,viewport.getScrollX());
        return distance;
    }
    @Test public void edgeScrollUsesVsyncTimeAndDepthInsteadOfFrameCount() throws Exception {
        targets();org.robolectric.shadows.ShadowChoreographer.setPaused(true);begin();
        int sixty=scrollFrames(60,root.getWidth()-2),oneTwenty=scrollFrames(120,root.getWidth()-2);
        assertTrue(sixty>100);assertEquals("same half-second distance at 60 and 120 Hz",sixty,oneTwenty,1);
        int gentle=scrollFrames(120,root.getWidth()-34);
        assertTrue("closer to edge scrolls faster",gentle<oneTwenty/2);
        drag(DragEvent.ACTION_DRAG_ENDED,0,0,false);
    }
    @Test @org.robolectric.annotation.GraphicsMode(org.robolectric.annotation.GraphicsMode.Mode.NATIVE)
    public void suggestionsFollowClearAndWholeBlankSquareOnlyInShelf() throws Exception {
        TemporaryShelf shelf=(TemporaryShelf)field(overlay,"shelf");
        shelf.add(List.of(),List.of("用户暂存"),Map.of());
        shelf.suggest(List.of(new RecentMediaSuggestions.Media(syntheticPicture(),"new.jpg",1),
            new RecentMediaSuggestions.Media("content://media/external/video/media/92","new.mp4",2)));
        ((View)field(overlay,"shelfTab")).performClick();draw();
        LinearLayout row=(LinearLayout)field(overlay,"row");assertEquals(5,row.getChildCount());
        assertEquals("用户暂存",((ReceiveNotifications.Receipt)row.getChildAt(0).getTag()).text);
        assertEquals("清空当前列表",row.getChildAt(1).getContentDescription());
        View blank=row.getChildAt(2);assertEquals("open-app-space",blank.getTag());
        assertNull(blank.getBackground());assertEquals(blank.getHeight(),blank.getWidth());
        for(int i=3;i<5;i++)assertTrue(shelf.isSuggested(((ReceiveNotifications.Receipt)row.getChildAt(i).getTag()).id));
        waitForImage(row.getChildAt(3));
        ((HorizontalScrollView)field(overlay,"scroll")).scrollTo(row.getWidth(),0);
        capture("media-after-blank");
        ((View)field(overlay,"count")).performClick();draw();
        assertEquals(3,((LinearLayout)field(overlay,"row")).getChildCount());
        assertEquals(1,((Map<?,?>)field(overlay,"items")).size());
    }
    @Test @org.robolectric.annotation.GraphicsMode(org.robolectric.annotation.GraphicsMode.Mode.NATIVE)
    public void emptyShelfKeepsInitialViewportBlankAndCanSwipeToMedia() throws Exception {
        TemporaryShelf shelf=(TemporaryShelf)field(overlay,"shelf");shelf.clear();
        shelf.suggest(List.of(new RecentMediaSuggestions.Media(syntheticPicture(),"new.jpg",1)));
        ((View)field(overlay,"shelfTab")).performClick();draw();
        LinearLayout row=(LinearLayout)field(overlay,"row");assertEquals(2,row.getChildCount());
        HorizontalScrollView viewport=(HorizontalScrollView)field(overlay,"scroll");
        View blank=row.getChildAt(0),media=row.getChildAt(1);
        assertEquals("open-app-space",blank.getTag());assertTrue(blank.getWidth()>=viewport.getWidth()-viewport.getPaddingLeft()-viewport.getPaddingRight());
        assertTrue("suggestion starts outside initial viewport",media.getLeft()>=viewport.getWidth()-viewport.getPaddingLeft());
        capture("media-empty-initial");
        android.content.pm.ResolveInfo launcher=new android.content.pm.ResolveInfo();launcher.activityInfo=new android.content.pm.ActivityInfo();
        launcher.activityInfo.packageName=activity.getPackageName();launcher.activityInfo.name="test.GlobalSendActivity";
        launcher.activityInfo.applicationInfo=new android.content.pm.ApplicationInfo();launcher.activityInfo.applicationInfo.packageName=activity.getPackageName();
        Shadows.shadowOf(activity.getPackageManager()).addResolveInfoForIntent(new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER).setPackage(activity.getPackageName()),launcher);
        tap(bounds(blank));idle(50);tap(bounds(blank));idle(400);
        assertEquals("test.GlobalSendActivity",Shadows.shadowOf(RuntimeEnvironment.getApplication()).getNextStartedActivity().getComponent().getClassName());
        assertEquals(1,shelf.items.size());
        Rect area=bounds(viewport);int windowX=((WindowManager.LayoutParams)root.getLayoutParams()).x;
        long now=android.os.SystemClock.uptimeMillis();
        for(int i=0;i<5;i++) {
            int action=i==0?MotionEvent.ACTION_DOWN:i==4?MotionEvent.ACTION_UP:MotionEvent.ACTION_MOVE;
            MotionEvent event=MotionEvent.obtain(now,now+i*40,action,area.right-24-i*30,area.centerY(),0);
            root.dispatchTouchEvent(event);event.recycle();
        }
        idle(120);draw();
        assertTrue("empty region must scroll rather than move window",viewport.getScrollX()>0);
        assertEquals(windowX,((WindowManager.LayoutParams)root.getLayoutParams()).x);
        waitForImage(media);capture("media-empty-swiped");
        media.findViewWithTag("remove-item").performClick();draw();
        assertTrue(shelf.items.isEmpty());assertEquals(1,row.getChildCount());
        assertEquals("open-app-space",row.getChildAt(0).getTag());
    }
    private String syntheticPicture() throws Exception {
        java.io.File file=new java.io.File(activity.getFilesDir(),"suggestion.jpg");
        android.graphics.Bitmap picture=android.graphics.Bitmap.createBitmap(240,160,android.graphics.Bitmap.Config.ARGB_8888);
        android.graphics.Canvas canvas=new android.graphics.Canvas(picture);canvas.drawColor(0xff2b6f84);
        android.graphics.Paint paint=new android.graphics.Paint();paint.setColor(0xffeab96c);canvas.drawCircle(150,50,38,paint);
        paint.setColor(0xff426f52);canvas.drawRect(0,100,240,160,paint);
        try(java.io.FileOutputStream output=new java.io.FileOutputStream(file)) {picture.compress(android.graphics.Bitmap.CompressFormat.JPEG,90,output);}
        picture.recycle();return file.getPath();
    }
    private void waitForImage(View card) throws Exception {
        android.widget.ImageView image=(android.widget.ImageView)((android.view.ViewGroup)card).getChildAt(0);
        for(int i=0;i<150 && image.getDrawable()==null;i++) {Thread.sleep(5);idle(10);}
        assertNotNull("native thumbnail must be rendered",image.getDrawable());
    }
}
