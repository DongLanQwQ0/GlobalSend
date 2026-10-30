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
        if(action==DragEvent.ACTION_DRAG_STARTED) {
            java.lang.reflect.Method receive=ReceiveOverlay.class.getDeclaredMethod("receiveDrop",DragEvent.class);receive.setAccessible(true);
            return (Boolean)receive.invoke(overlay,event);
        }
        if(action==DragEvent.ACTION_DRAG_ENDED) {
            DockCoordinator.LocalDrag session=(DockCoordinator.LocalDrag)AndroidDragTest.NativeDragView.states.get(index);
            session.accepted|=result;
            java.lang.reflect.Method finish=DockCoordinator.class.getDeclaredMethod("finishExport",DockCoordinator.LocalDrag.class);finish.setAccessible(true);finish.invoke(null,session);
            return true;
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
        drag(DragEvent.ACTION_DRAG_STARTED,25,55,false);
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
        drag(DragEvent.ACTION_DRAG_LOCATION,root.getWidth()-8,55,false);idle(150);
        int right=viewport.getScrollX();assertTrue("hovering right keeps scrolling without new motion",right>0);
        drag(DragEvent.ACTION_DRAG_LOCATION,8,55,false);idle(80);assertTrue(viewport.getScrollX()<right);
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
}
