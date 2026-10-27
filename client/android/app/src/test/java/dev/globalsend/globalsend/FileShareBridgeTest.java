package dev.globalsend.globalsend;

import static org.junit.Assert.*;
import android.app.Activity;
import android.content.ClipData;
import android.content.Intent;
import android.content.pm.ProviderInfo;
import android.net.Uri;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodChannel;
import java.io.File;
import java.nio.ByteBuffer;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.TimeUnit;
import org.junit.After;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.Robolectric;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.Shadows;
import org.robolectric.annotation.Config;
import org.robolectric.shadows.ShadowContentResolver;
import org.robolectric.util.ReflectionHelpers;

@RunWith(RobolectricTestRunner.class)
@Config(sdk=28,manifest=Config.NONE)
public class FileShareBridgeTest {
  private Activity activity;
  private FileShareBridge bridge;
  private final BinaryMessenger messenger=new BinaryMessenger(){
    @Override public void send(String name,ByteBuffer value){}
    @Override public void send(String name,ByteBuffer value,BinaryReply reply){}
    @Override public void setMessageHandler(String name,BinaryMessageHandler handler){}
  };
  @Before public void setup(){
    activity=Robolectric.buildActivity(Activity.class).setup().get();
    DockShareProvider provider=new DockShareProvider();ProviderInfo info=new ProviderInfo();info.authority=activity.getPackageName()+".dock-files";provider.attachInfo(activity,info);ShadowContentResolver.registerProviderInternal(info.authority,provider);
    bridge=new FileShareBridge(activity,new MethodChannel(messenger,"test-share"),()->activity);
  }
  @After public void teardown(){bridge.dispose();activity.finish();}
  private File file(String name,String bytes)throws Exception{File file=new File(activity.getFilesDir(),name);Files.write(file.toPath(),bytes.getBytes(java.nio.charset.StandardCharsets.UTF_8));return file;}
  private String read(File file)throws Exception{return new String(Files.readAllBytes(file.toPath()),java.nio.charset.StandardCharsets.UTF_8);}
  private void imported()throws Exception{ExecutorService worker=ReflectionHelpers.getField(bridge,"importer");worker.submit(()->{}).get(10,TimeUnit.SECONDS);Shadows.shadowOf(android.os.Looper.getMainLooper()).idle();}
  @Test public void outgoingManyUsesNativeChooserReadableUrisAndClipDataWithoutCopyingOriginals()throws Exception{
    File first=file("one.png","one"),second=file("two.mp4","two");
    bridge.share(List.of(first.getPath(),second.getPath()),"https://example.test");
    Intent chooser=Shadows.shadowOf(activity).getNextStartedActivity();assertEquals(Intent.ACTION_CHOOSER,chooser.getAction());
    Intent target=chooser.getParcelableExtra(Intent.EXTRA_INTENT);assertEquals(Intent.ACTION_SEND_MULTIPLE,target.getAction());
    assertEquals(2,target.<Uri>getParcelableArrayListExtra(Intent.EXTRA_STREAM).size());assertEquals(3,target.getClipData().getItemCount());
    assertTrue((target.getFlags()&Intent.FLAG_GRANT_READ_URI_PERMISSION)!=0);assertEquals("https://example.test",target.getStringExtra(Intent.EXTRA_TEXT));
    assertEquals("one",read(first));assertEquals("two",read(second));
    Uri uri=target.getClipData().getItemAt(0).getUri();assertEquals("one",new String(activity.getContentResolver().openInputStream(uri).readAllBytes()));
  }
  @Test public void externalClipAndExtrasDeduplicateAndStayPendingAcrossRestartUntilAck()throws Exception{
    File first=file("source.a","a"),second=file("source.b","b");
    Uri a=DockShareProvider.register(activity,first,first.getName()),b=DockShareProvider.register(activity,second,second.getName());
    ClipData clip=ClipData.newUri(activity.getContentResolver(),"files",a);clip.addItem(new ClipData.Item(b));clip.addItem(new ClipData.Item("caption"));
    Intent intent=new Intent(Intent.ACTION_SEND_MULTIPLE).putParcelableArrayListExtra(Intent.EXTRA_STREAM,new ArrayList<>(List.of(a,b,a))).putStringArrayListExtra(Intent.EXTRA_TEXT,new ArrayList<>(List.of("caption","other text")));intent.setClipData(clip);
    assertTrue(bridge.handleIntent(intent));assertFalse(bridge.handleIntent(intent));imported();
    List<Map<String,Object>> pending=bridge.pending();assertEquals(1,pending.size());Map<String,Object> batch=pending.get(0);
    List<?> paths=(List<?>)batch.get("paths");assertEquals(2,paths.size());assertEquals(List.of("caption","other text"),batch.get("texts"));
    assertEquals("a",read(new File((String)paths.get(0))));assertEquals("b",read(new File((String)paths.get(1))));
    assertEquals(batch.get("batchId"),bridge.pending().get(0).get("batchId"));
    bridge.dispose();bridge=new FileShareBridge(activity,new MethodChannel(messenger,"test-share-restart"),()->activity);
    assertEquals(batch.get("batchId"),bridge.pending().get(0).get("batchId"));bridge.ack((String)batch.get("batchId"));
    assertTrue(bridge.pending().isEmpty());assertTrue(new File((String)paths.get(0)).isFile());assertEquals("a",read(first));
  }
  @Test public void textOnlyMultipleAndUrlsDoNotBecomeFiles()throws Exception{
    Intent intent=new Intent(Intent.ACTION_SEND).putStringArrayListExtra(Intent.EXTRA_TEXT,new ArrayList<>(List.of("https://example.test","plain text")));
    bridge.handleIntent(intent);imported();Map<String,Object> batch=bridge.pending().get(0);
    assertTrue(((List<?>)batch.get("paths")).isEmpty());assertEquals(List.of("https://example.test","plain text"),batch.get("texts"));
    bridge.share(List.of(),"plain text");Intent chooser=Shadows.shadowOf(activity).getNextStartedActivity();Intent target=chooser.getParcelableExtra(Intent.EXTRA_INTENT);
    assertEquals(Intent.ACTION_SEND,target.getAction());assertEquals("text/plain",target.getType());assertEquals("plain text",target.getClipData().getItemAt(0).getText().toString());
  }
  @Test public void moreThanSixtyFourExplicitSharedFilesAreNotTruncated()throws Exception{
    List<String> paths=new ArrayList<>();for(int i=0;i<70;i++)paths.add(file("file"+i+".unknown","data"+i).getPath());
    bridge.share(paths,null);Intent chooser=Shadows.shadowOf(activity).getNextStartedActivity();Intent target=chooser.getParcelableExtra(Intent.EXTRA_INTENT);
    assertEquals(70,target.<Uri>getParcelableArrayListExtra(Intent.EXTRA_STREAM).size());assertEquals(70,target.getClipData().getItemCount());assertEquals("application/octet-stream",target.getType());
  }
}
