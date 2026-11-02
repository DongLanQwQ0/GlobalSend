package dev.globalsend.globalsend;

import static org.junit.Assert.*;
import android.database.Cursor;
import android.provider.DocumentsContract.Document;
import java.io.FileNotFoundException;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicInteger;
import org.junit.After;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.annotation.Config;

/** Provider metadata and lazy resolution; physical target-app support is separate. */
@RunWith(RobolectricTestRunner.class)
@Config(sdk=34,manifest=Config.NONE)
public class RemoteReferenceProviderTest {
    @After public void clear(){RemoteReferenceFiles.stop();}
    private Map<String,Object> file(){return Map.of("id","copied:peer:offer:item","name","note.txt","kind","file","size",12L);}

    @Test public void metadataDoesNotDownloadAndReadersCoalesce() throws Exception {
        AtomicInteger calls=new AtomicInteger();
        RemoteReferenceFiles.listen(request -> calls.incrementAndGet());
        RemoteReferenceFiles.Entry entry=RemoteReferenceFiles.register(file());
        RemoteReferenceProvider provider=new RemoteReferenceProvider();
        try(Cursor row=provider.queryDocument(entry.token+":note.txt",null)) {
            assertTrue(row.moveToFirst());
            assertEquals("note.txt",row.getString(row.getColumnIndexOrThrow(Document.COLUMN_DISPLAY_NAME)));
            assertEquals(12,row.getLong(row.getColumnIndexOrThrow(Document.COLUMN_SIZE)));
            assertEquals("text/plain",row.getString(row.getColumnIndexOrThrow(Document.COLUMN_MIME_TYPE)));
        }
        assertEquals(0,calls.get());
        assertSame(entry.resolve(),entry.resolve());assertEquals(1,calls.get());
        assertFalse(entry.local.isDone());
        RemoteReferenceFiles.complete(entry.token,List.of("/actual/renamed-note.txt"),"");
        assertEquals("/actual/renamed-note.txt",entry.local.get());
    }

    @Test public void fullTreePreservesEmptyDirectoriesWithoutZip() throws Exception {
        RemoteReferenceFiles.Entry entry=RemoteReferenceFiles.register(Map.of("name","Folder","kind","directory","entries",List.of(
            Map.of("relativePath","Folder","kind","directory"),
            Map.of("relativePath","Folder/empty","kind","directory"),
            Map.of("relativePath","Folder/note.txt","kind","file","size",12))));
        RemoteReferenceProvider provider=new RemoteReferenceProvider();
        try(Cursor children=provider.queryChildDocuments(entry.token+":Folder",null,(String)null)) {
            assertEquals(2,children.getCount());assertTrue(children.moveToFirst());
            assertEquals("empty",children.getString(children.getColumnIndexOrThrow(Document.COLUMN_DISPLAY_NAME)));
            assertEquals(Document.MIME_TYPE_DIR,children.getString(children.getColumnIndexOrThrow(Document.COLUMN_MIME_TYPE)));
        }
        try(Cursor empty=provider.queryChildDocuments(entry.token+":Folder/empty",null,(String)null)){assertEquals(0,empty.getCount());}
        assertTrue(provider.isChildDocument(entry.token+":Folder",entry.token+":Folder/note.txt"));
        assertFalse(entry.requested);
        assertThrows(IllegalArgumentException.class,()->RemoteReferenceFiles.register(Map.of("name","Folder","kind","directory")));
    }

    @Test public void failureStopAndFreshRetryCompleteInsteadOfHanging() throws Exception {
        RemoteReferenceFiles.listen(request -> {});
        RemoteReferenceFiles.Entry first=RemoteReferenceFiles.register(file());first.resolve();
        RemoteReferenceFiles.complete(first.token,List.of(),"source offline");
        assertThrows(java.util.concurrent.ExecutionException.class,()->first.local.get());
        RemoteReferenceFiles.Entry retry=RemoteReferenceFiles.register(file());retry.resolve();
        RemoteReferenceFiles.complete(retry.token,List.of("/downloaded/note.txt"),"");
        assertEquals("/downloaded/note.txt",retry.local.get());
        RemoteReferenceFiles.Entry stopping=RemoteReferenceFiles.register(file());stopping.resolve();RemoteReferenceFiles.stop();
        assertThrows(java.util.concurrent.ExecutionException.class,()->stopping.local.get());
        assertThrows(FileNotFoundException.class,()->RemoteReferenceFiles.entry(stopping.token+":note.txt"));
    }

    @Test public void listenerFailureIsDeliveredAndUnusedSourceNeverRequests() throws Exception {
        AtomicInteger calls=new AtomicInteger();
        RemoteReferenceFiles.listen(request -> {calls.incrementAndGet();throw new IllegalStateException("engine closed");});
        RemoteReferenceFiles.register(file());assertEquals(0,calls.get());
        RemoteReferenceFiles.Entry reading=RemoteReferenceFiles.register(file());reading.resolve();
        assertThrows(java.util.concurrent.ExecutionException.class,()->reading.local.get());assertEquals(1,calls.get());
    }

    @Test public void actualReaderWaitsOffUiThenReadsRealBytesAtRequestedOffset() throws Exception {
        android.content.Context context=org.robolectric.RuntimeEnvironment.getApplication();
        java.io.File file=new java.io.File(context.getCacheDir(),"remote-reader.txt");
        java.nio.file.Files.write(file.toPath(),"real-contents".getBytes(java.nio.charset.StandardCharsets.UTF_8));
        java.util.concurrent.CountDownLatch requested=new java.util.concurrent.CountDownLatch(1);
        RemoteReferenceFiles.listen(request -> requested.countDown());
        RemoteReferenceFiles.Entry entry=RemoteReferenceFiles.register(file());
        android.os.ProxyFileDescriptorCallback reader=RemoteReferenceFiles.reader(context,entry,entry.parts.get(0));
        assertEquals(12,reader.onGetSize());assertFalse(entry.requested);
        java.util.concurrent.ExecutorService executor=java.util.concurrent.Executors.newSingleThreadExecutor();
        try {
            java.util.concurrent.Future<String> reading=executor.submit(() -> {
                byte[] bytes=new byte[8];int count=reader.onRead(5,8,bytes);return new String(bytes,0,count,java.nio.charset.StandardCharsets.UTF_8);
            });
            assertTrue(requested.await(2,java.util.concurrent.TimeUnit.SECONDS));assertFalse(reading.isDone());
            RemoteReferenceFiles.complete(entry.token,List.of(file.toString()),"");
            assertEquals("contents",reading.get(2,java.util.concurrent.TimeUnit.SECONDS));
        } finally {reader.onRelease();executor.shutdownNow();file.delete();}
    }
}
