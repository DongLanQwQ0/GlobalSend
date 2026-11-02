package dev.globalsend.globalsend;

import static org.junit.Assert.*;
import android.app.Activity;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodChannel;
import java.nio.ByteBuffer;
import java.util.Map;
import org.junit.After;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.Robolectric;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;
import org.robolectric.annotation.Config;
import org.robolectric.util.ReflectionHelpers;

@RunWith(RobolectricTestRunner.class)
@Config(sdk=34,manifest=Config.NONE)
public class ClipboardSlotOverlayTest {
    private BinaryMessenger.BinaryMessageHandler inbound;
    private Activity activity;private DockCoordinator coordinator;private ReceiveOverlay overlay;
    private final java.util.List<Map<?,?>> leases=new java.util.ArrayList<>();
    @Before public void setUp() {
        activity=Robolectric.buildActivity(Activity.class).setup().get();
        coordinator=new DockCoordinator(activity,new MethodChannel(new BinaryMessenger(){
            public void send(String name,ByteBuffer value){send(name,value,null);}
            public void send(String name,ByteBuffer value,BinaryReply reply){
                ByteBuffer copy=value.duplicate();copy.flip();
                io.flutter.plugin.common.MethodCall call=io.flutter.plugin.common.StandardMethodCodec.INSTANCE.decodeMethodCall(copy);
                if(call.method.equals("clipboardSlotLease"))leases.add((Map<?,?>)call.arguments);
            }
            public void setMessageHandler(String name,BinaryMessageHandler handler){inbound=handler;}
        },"slot-test"));
        overlay=new ReceiveOverlay(RuntimeEnvironment.getApplication(),new ReceiveOverlay.Actions(){
            public void open(String id){}public void copy(String id){}
            public void dismiss(Map<String,String> versions,long generation){}
        });
    }
    @After public void tearDown(){coordinator.dispose();overlay.hide();activity.finish();}
    private void slot(String text){
        ReflectionHelpers.setField(coordinator,"clipboardSlot",Map.of("kind","text","text",text,"sourceLabel","peer"));
        ReceiveOverlay.clipboardSlotChanged();
    }
    @SuppressWarnings("unchecked")
    @Test public void latestSingleSlotPrecedesHistoryWithoutCreatingOrOpeningWindow(){
        Map<String,ReceiveNotifications.Receipt> ordinary=ReflectionHelpers.getField(overlay,"items");
        ordinary.put("ordinary",new ReceiveNotifications.Receipt("ordinary","1","peer","old",null,null,0));
        slot("first");slot("latest");
        Map<String,ReceiveNotifications.Receipt> displayed=ReflectionHelpers.callInstanceMethod(overlay,"displayed");
        assertEquals(2,displayed.size());assertEquals("clipboard-slot",displayed.keySet().iterator().next());
        assertEquals("latest",displayed.get("clipboard-slot").text);
        assertEquals(1,ordinary.size());assertFalse(ordinary.containsKey("clipboard-slot"));
        assertNull(ReflectionHelpers.getField(overlay,"root"));
        DockCoordinator.clearClipboardSlot();
        displayed=ReflectionHelpers.callInstanceMethod(overlay,"displayed");
        assertEquals(1,displayed.size());assertTrue(displayed.containsKey("ordinary"));
    }
    @Test public void nativeOwnerReleasesExactlyOnceAtActualEnd(){
        NativeFileLease lease=new NativeFileLease(java.util.List.of("/cache/clipboard-slot-cache/current.png"));
        org.robolectric.Shadows.shadowOf(android.os.Looper.getMainLooper()).idle();
        assertEquals(1,leases.size());assertEquals(true,leases.get(0).get("active"));
        lease.close();lease.close();
        org.robolectric.Shadows.shadowOf(android.os.Looper.getMainLooper()).idle();
        assertEquals(2,leases.size());assertEquals(false,leases.get(1).get("active"));
        assertEquals(leases.get(0).get("paths"),leases.get(1).get("paths"));
    }
    @Test public void legacyImageCopyBridgeReturnsUnsupportedWithoutWritingOrOpeningSource() {
        android.content.ClipboardManager manager=activity.getSystemService(android.content.ClipboardManager.class);
        manager.setPrimaryClip(android.content.ClipData.newPlainText("fixture","preserve clipboard"));
        io.flutter.plugin.common.StandardMethodCodec codec=io.flutter.plugin.common.StandardMethodCodec.INSTANCE;
        ByteBuffer message=codec.encodeMethodCall(new io.flutter.plugin.common.MethodCall("copyReceivedImage",Map.of("path","/not-a-readable-file.png")));message.flip();
        final Object[] returned=new Object[1];inbound.onMessage(message,reply->{ByteBuffer copy=reply.duplicate();copy.flip();returned[0]=codec.decodeEnvelope(copy);});
        assertEquals(false,returned[0]);assertEquals("preserve clipboard",manager.getPrimaryClip().getItemAt(0).getText().toString());assertTrue(leases.isEmpty());
    }
    @Test public void imageSlotCopyIsNotAnActionButTextCopyRemainsAvailable() {
        android.content.ClipboardManager manager=activity.getSystemService(android.content.ClipboardManager.class);
        manager.setPrimaryClip(android.content.ClipData.newPlainText("fixture","preserve clipboard"));
        int before=org.robolectric.shadows.ShadowToast.shownToastCount();
        ReflectionHelpers.callInstanceMethod(overlay,"copy",ReflectionHelpers.ClassParameter.from(ReceiveNotifications.Receipt.class,new ReceiveNotifications.Receipt("clipboard-slot","1","peer",null,"image.png","/image.png",3)));
        assertEquals("preserve clipboard",manager.getPrimaryClip().getItemAt(0).getText().toString());assertEquals(before,org.robolectric.shadows.ShadowToast.shownToastCount());
        ReflectionHelpers.callInstanceMethod(overlay,"copy",ReflectionHelpers.ClassParameter.from(ReceiveNotifications.Receipt.class,new ReceiveNotifications.Receipt("clipboard-slot","2","peer","copied text",null,null,0)));
        assertEquals("copied text",manager.getPrimaryClip().getItemAt(0).getText().toString());
    }

}
