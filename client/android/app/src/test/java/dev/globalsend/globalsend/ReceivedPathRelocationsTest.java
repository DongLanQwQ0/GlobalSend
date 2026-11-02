package dev.globalsend.globalsend;

import static org.junit.Assert.*;
import android.app.Application;
import android.os.Environment;
import android.os.Looper;
import android.os.Process;
import android.os.storage.StorageManager;
import java.io.File;
import java.nio.file.Files;
import java.nio.charset.StandardCharsets;
import java.util.Map;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.TimeUnit;
import org.json.JSONArray;
import org.json.JSONObject;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;
import org.robolectric.Shadows;
import org.robolectric.annotation.Config;
import org.robolectric.shadows.ShadowMediaScannerConnection;
import org.robolectric.shadows.StorageVolumeBuilder;

@RunWith(RobolectricTestRunner.class)
@Config(sdk=34,manifest=Config.NONE)
public class ReceivedPathRelocationsTest {
    private Application app;
    @Before public void setup() throws Exception {
        app=RuntimeEnvironment.getApplication();app.getFilesDir().mkdirs();
        ReceivedPathRelocations.forgetForTest(app);
        for(String name:List.of("saved-files.json","temporary-shelf.json","received-path-relocations.json","received-path-relocations.json.bak"))Files.deleteIfExists(new File(app.getFilesDir(),name).toPath());
    }
    private File bytes(String path) throws Exception {
        File file=new File(app.getFilesDir(),path);file.getParentFile().mkdirs();Files.write(file.toPath(),"original bytes".getBytes(StandardCharsets.UTF_8));return file;
    }
    private void records(String path) throws Exception {
        JSONArray values=new JSONArray().put(new JSONObject().put("id","kept").put("path",path).put("name","photo.jpg"))
            .put(new JSONObject().put("id","text").put("path","").put("text","keep text"));
        Files.write(new File(app.getFilesDir(),"temporary-shelf.json").toPath(),values.toString().getBytes(StandardCharsets.UTF_8));
    }
    private void index(Map<String,String> aliases) throws Exception {
        Files.write(new File(app.getFilesDir(),"saved-files.json").toPath(),new JSONObject().put("relocatedLocations",new JSONObject(aliases)).put("files",new JSONArray()).toString().getBytes(StandardCharsets.UTF_8));
    }
    private ExecutorService io(TemporaryShelf shelf) throws Exception {
        var field=TemporaryShelf.class.getDeclaredField("io");field.setAccessible(true);return (ExecutorService)field.get(shelf);
    }
    private void ioIdle(TemporaryShelf shelf) throws Exception {io(shelf).submit(() -> {}).get(5,TimeUnit.SECONDS);}
    private void flush(TemporaryShelf shelf) throws Exception {ioIdle(shelf);Shadows.shadowOf(Looper.getMainLooper()).idle();ioIdle(shelf);}
    private String persistedPath() throws Exception {
        JSONArray values=new JSONArray(new String(Files.readAllBytes(new File(app.getFilesDir(),"temporary-shelf.json").toPath()),StandardCharsets.UTF_8));
        for(int i=0;i<values.length();i++)if("kept".equals(values.getJSONObject(i).getString("id")))return values.getJSONObject(i).getString("path");return null;
    }
    @Test public void migrationCommittedBeforeShelfLoadRecoversOldBuildReferencesFromDartIndex() throws Exception {
        File old=bytes("old/profile/device/id/photo.jpg"),next=bytes("flat/photo.jpg");records(old.getPath());index(Map.of(old.getPath(),next.getPath()));Files.delete(old.toPath());
        TemporaryShelf shelf=new TemporaryShelf(app,() -> {});flush(shelf);
        assertEquals(2,shelf.items.size());assertEquals(next.getPath(),shelf.items.get("kept").localPath);assertEquals(next.getPath(),persistedPath());
        assertEquals("original bytes",new String(Files.readAllBytes(next.toPath()),StandardCharsets.UTF_8));
    }
    @Test public void alreadyLoadedShelfAndPendingExportFollowNativeBridgeRelocation() throws Exception {
        File old=bytes("old-before/photo.jpg"),next=bytes("flat-before/photo.jpg");records(old.getPath());
        TemporaryShelf shelf=new TemporaryShelf(app,() -> {});flush(shelf);
        ReceiveNotifications.Receipt original=shelf.items.get("kept");shelf.exported(List.of(original),true,item -> item.localPath.equals(old.getPath()));
        index(Map.of(old.getPath(),next.getPath()));ReceiveDirectory.relocateReferences(app,Map.of(old.getPath(),next.getPath()));Files.delete(old.toPath());
        Shadows.shadowOf(Looper.getMainLooper()).idle();flush(shelf);
        assertEquals(next.getPath(),shelf.items.get("kept").localPath);assertEquals(next.getPath(),persistedPath());assertTrue(shelf.pendingRemoval("kept"));
        Shadows.shadowOf(Looper.getMainLooper()).idleFor(java.time.Duration.ofSeconds(3));assertFalse(shelf.items.containsKey("kept"));assertTrue(next.isFile());
    }
    @Test public void relocationBetweenIoRestoreAndMainMergeRepairsBeforeMissingFilePrune() throws Exception {
        File old=bytes("old-race/photo.jpg"),next=bytes("flat-race/photo.jpg");records(old.getPath());
        TemporaryShelf shelf=new TemporaryShelf(app,() -> {});ioIdle(shelf);
        index(Map.of(old.getPath(),next.getPath()));ReceiveDirectory.relocateReferences(app,Map.of(old.getPath(),next.getPath()));Files.delete(old.toPath());
        flush(shelf);assertEquals(next.getPath(),shelf.items.get("kept").localPath);assertEquals(2,shelf.items.size());
    }
    @Test public void restartUsesDurableNativeAliasesAndTrueDeletionStillRemovesTheReference() throws Exception {
        File old=bytes("old-restart/photo.jpg"),next=bytes("flat-restart/photo.jpg");records(old.getPath());
        ReceiveDirectory.relocateReferences(app,Map.of(old.getPath(),next.getPath()));Files.delete(old.toPath());
        ReceivedPathRelocations.forgetForTest(app);TemporaryShelf restored=new TemporaryShelf(app,() -> {});flush(restored);
        assertEquals(next.getPath(),restored.items.get("kept").localPath);
        Files.delete(next.toPath());ReceivedPathRelocations.forgetForTest(app);TemporaryShelf deleted=new TemporaryShelf(app,() -> {});flush(deleted);
        assertEquals(1,deleted.items.size());assertTrue(deleted.items.containsKey("text"));
    }
    @Test public void missingUnrelatedExternalOriginalIsNotKeptAsAMigration() throws Exception {
        File missing=new File(app.getFilesDir(),"external-user-removed.jpg");records(missing.getPath());
        TemporaryShelf shelf=new TemporaryShelf(app,() -> {});flush(shelf);
        assertFalse(shelf.items.containsKey("kept"));assertTrue(shelf.items.containsKey("text"));
    }
    @Test public void emptyFinalImageIsRememberedBeforeWriteWithoutScanningUntilCompletion() throws Exception {
        File root=Environment.getExternalStorageDirectory().getCanonicalFile();
        var storage=Shadows.shadowOf(app.getSystemService(StorageManager.class));storage.resetStorageVolumeList();
        storage.addStorageVolume(new StorageVolumeBuilder("primary",root,"Primary",Process.myUserHandle(),Environment.MEDIA_MOUNTED).setIsPrimary(true).build());
        File image=new File(root,"Download/GlobalSend-origin/photo.jpg");image.getParentFile().mkdirs();Files.write(image.toPath(),new byte[0]);
        ReceiveDirectory.rememberOrigin(app,image.getPath());
        assertTrue(ReceivedFilePublication.receivedPaths(app).contains(image.getCanonicalPath()));assertTrue(ShadowMediaScannerConnection.getSavedPaths().isEmpty());
        Files.write(image.toPath(),new byte[]{1,2,3});assertTrue(ReceivedFilePublication.publish(app,image.getPath(),null));
        assertTrue(ShadowMediaScannerConnection.getSavedPaths().contains(image.getPath()));assertEquals(3,image.length());
    }
    @Test public void actualMethodChannelAckFollowsDurableMapAndLiveShelfUpdate() throws Exception {
        File old=bytes("channel-old/photo.jpg"),next=bytes("channel-new/photo.jpg");records(old.getPath());
        TemporaryShelf shelf=new TemporaryShelf(app,() -> {});flush(shelf);index(Map.of(old.getPath(),next.getPath()));
        var handler=new java.util.concurrent.atomic.AtomicReference<io.flutter.plugin.common.BinaryMessenger.BinaryMessageHandler>();
        io.flutter.plugin.common.BinaryMessenger messenger=new io.flutter.plugin.common.BinaryMessenger(){
            public void send(String name,java.nio.ByteBuffer message){}
            public void send(String name,java.nio.ByteBuffer message,BinaryReply reply){}
            public void setMessageHandler(String name,BinaryMessageHandler value){handler.set(value);}
        };
        ReceiveDirectory directory=new ReceiveDirectory(app,new io.flutter.plugin.common.MethodChannel(messenger,"reference-test"),
            (descriptor,writable) -> {throw new AssertionError("relocation does not open or copy a file");});
        var reply=new java.util.concurrent.atomic.AtomicReference<java.nio.ByteBuffer>();
        var codec=io.flutter.plugin.common.StandardMethodCodec.INSTANCE;
        java.nio.ByteBuffer message=codec.encodeMethodCall(new io.flutter.plugin.common.MethodCall("relocateReferences",Map.of("locations",Map.of(old.getPath(),next.getPath()))));message.flip();
        handler.get().onMessage(message,bytes -> {
            assertEquals(next.getPath(),shelf.items.get("kept").localPath);
            try {
                assertEquals(next.getPath(),new JSONObject(new String(Files.readAllBytes(new File(app.getFilesDir(),"received-path-relocations.json").toPath()),StandardCharsets.UTF_8)).getString(old.getPath()));
                assertTrue(old.isFile());Files.delete(old.toPath());
            }catch(Exception failure){throw new AssertionError(failure);}
            reply.set(bytes);
        });
        var field=ReceiveDirectory.class.getDeclaredField("io");field.setAccessible(true);
        ((ExecutorService)field.get(directory)).submit(() -> {}).get(5,TimeUnit.SECONDS);
        Shadows.shadowOf(Looper.getMainLooper()).idle();assertNotNull(reply.get());reply.get().flip();assertNull(codec.decodeEnvelope(reply.get()));
        assertFalse(old.exists());assertTrue(next.exists());flush(shelf);directory.dispose();
    }
}
