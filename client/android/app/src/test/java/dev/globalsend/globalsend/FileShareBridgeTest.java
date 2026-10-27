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
@Config(sdk=28,manifest=Config.NONE,shadows=ReceiveDirectoryTest.ModernDocumentQueries.class)
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
  @Test public void sharedDocumentDirectoryAndTreeRootKeepStructureEmptyFoldersAndOriginalBytes()throws Exception{
    FolderDocumentsTest.Tree provider=new FolderDocumentsTest.Tree();provider.disk=new File(activity.getCacheDir(),"shared-folder-fixture");provider.disk.mkdirs();
    ProviderInfo info=new ProviderInfo();info.authority="folder-fixtures";info.exported=true;info.grantUriPermissions=true;
    info.readPermission=android.Manifest.permission.MANAGE_DOCUMENTS;info.writePermission=android.Manifest.permission.MANAGE_DOCUMENTS;
    provider.attachInfo(activity,info);ShadowContentResolver.registerProviderInternal(info.authority,provider);
    String source=provider.add("root","资料",true),nested=provider.add(source,"子目录",true),leaf=provider.add(nested,"正文.txt",false);
    provider.add(source,"空目录",true);Files.write(provider.entries.get(leaf).file.toPath(),"原始内容".getBytes(java.nio.charset.StandardCharsets.UTF_8));
    Intent first=new Intent(Intent.ACTION_SEND).putExtra(Intent.EXTRA_STREAM,provider.uri(source));
    bridge.handleIntent(first);imported();Map<String,Object> batch=bridge.pending().get(0);assertFalse(batch.containsKey("error"));
    File imported=new File((String)((List<?>)batch.get("paths")).get(0));assertEquals("资料",imported.getName());
    assertEquals("原始内容",read(new File(imported,"子目录/正文.txt")));assertTrue(new File(imported,"空目录").isDirectory());
    assertEquals("原始内容",read(provider.entries.get(leaf).file));assertTrue(provider.entries.get(source).file.isDirectory());
    bridge.ack((String)batch.get("batchId"));assertTrue(new File(imported,"子目录/正文.txt").isFile());
    Intent tree=new Intent(Intent.ACTION_SEND).putExtra(Intent.EXTRA_STREAM,android.provider.DocumentsContract.buildTreeDocumentUri(info.authority,source));
    bridge.handleIntent(tree);imported();Map<String,Object> treeBatch=bridge.pending().get(0);assertFalse(treeBatch.containsKey("error"));
    File importedTree=new File((String)((List<?>)treeBatch.get("paths")).get(0));assertEquals("原始内容",read(new File(importedTree,"子目录/正文.txt")));
    bridge.ack((String)treeBatch.get("batchId"));
    bridge.handleIntent(new Intent(Intent.ACTION_SEND).putExtra(Intent.EXTRA_STREAM,provider.uri(leaf)));imported();
    Map<String,Object> fileBatch=bridge.pending().get(0);assertFalse(fileBatch.containsKey("error"));
    assertEquals("原始内容",read(new File((String)((List<?>)fileBatch.get("paths")).get(0))));
  }
}
