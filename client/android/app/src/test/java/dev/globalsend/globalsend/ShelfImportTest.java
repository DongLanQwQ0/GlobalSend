package dev.globalsend.globalsend;

import static org.junit.Assert.*;
import android.app.Activity;
import android.content.ClipData;
import android.content.pm.ProviderInfo;
import android.os.Looper;
import android.view.DragEvent;
import android.view.View;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.StandardMethodCodec;
import java.io.File;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.Robolectric;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.Shadows;
import org.robolectric.annotation.Config;
import org.robolectric.shadows.ShadowContentResolver;
import org.robolectric.util.ReflectionHelpers;

@RunWith(RobolectricTestRunner.class)
@Config(sdk=34, manifest=Config.NONE)
public class ShelfImportTest {
    @Test public void mixedExternalDropsCopyOnWorkerAndNeverPublishReceivedOrQueuedEvents() throws Exception {
        Activity activity=Robolectric.buildActivity(Activity.class).setup().get();
        List<MethodCall> events=new java.util.concurrent.CopyOnWriteArrayList<>();
        BinaryMessenger messenger=new BinaryMessenger() {
            @Override public void send(String channel,ByteBuffer message) { send(channel,message,null); }
            @Override public void send(String channel,ByteBuffer message,BinaryReply callback) {
                ByteBuffer copy=message.duplicate();copy.flip();events.add(StandardMethodCodec.INSTANCE.decodeMethodCall(copy));
            }
            @Override public void setMessageHandler(String channel,BinaryMessageHandler handler) {}
        };
        DockCoordinator coordinator=new DockCoordinator(activity,new MethodChannel(messenger,"shelf-test"));
        try {
            DockShareProvider provider=new DockShareProvider();ProviderInfo info=new ProviderInfo();info.authority=activity.getPackageName()+".dock-files";
            provider.attachInfo(activity,info);ShadowContentResolver.registerProviderInternal(info.authority,provider);
            File first=new File(activity.getFilesDir(),"document.pdf"),second=new File(activity.getFilesDir(),"video.mp4");
            Files.write(first.toPath(),"pdf bytes".getBytes(StandardCharsets.UTF_8));Files.write(second.toPath(),"video bytes".getBytes(StandardCharsets.UTF_8));
            ClipData clip=ClipData.newUri(activity.getContentResolver(),"mixed",DockShareProvider.register(activity,first,first.getName()));
            clip.addItem(new ClipData.Item(DockShareProvider.register(activity,second,second.getName())));clip.addItem(new ClipData.Item("一起暂存的文字"));
            DragEvent drop=ReflectionHelpers.callConstructor(DragEvent.class);
            ReflectionHelpers.setField(drop,"mAction",DragEvent.ACTION_DROP);ReflectionHelpers.setField(drop,"mClipData",clip);ReflectionHelpers.setField(drop,"mClipDescription",clip.getDescription());
            List<Map<String,Object>> imports=new ArrayList<>();
            assertTrue(DockCoordinator.importToShelf(drop,imports::add));
            long end=System.nanoTime()+java.util.concurrent.TimeUnit.SECONDS.toNanos(5);
            while(imports.isEmpty()&&System.nanoTime()<end){Shadows.shadowOf(Looper.getMainLooper()).idle();Thread.sleep(10);}
            assertEquals(1,imports.size());Map<String,Object> imported=imports.get(0);assertNull(imported.get("error"));
            List<?> paths=(List<?>)imported.get("paths");assertEquals(2,paths.size());
            assertTrue(paths.get(0).toString().contains("shelf-imports"));assertNotEquals(first.getPath(),paths.get(0));
            assertEquals("pdf bytes",new String(Files.readAllBytes(new File(paths.get(0).toString()).toPath()),StandardCharsets.UTF_8));
            assertEquals(List.of("一起暂存的文字"),imported.get("texts"));
            assertFalse(events.stream().anyMatch(event->event.method.equals("nativeDrop")));
        } finally {coordinator.dispose();activity.finish();}
    }
}
